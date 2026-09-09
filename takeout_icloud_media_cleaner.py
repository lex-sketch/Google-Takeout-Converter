# -*- coding: utf-8 -*-
"""
Takeout → iCloud Photo/Video Cleaner & Converter

Enhancements over the previous version:
- Adds **video** conversion using ffmpeg to iCloud-friendly MP4 (H.264 + AAC)
- Optional **sidecar JSON injection** to preserve capture date and GPS
  - Images: writes EXIF DateTimeOriginal & GPS (requires piexif; optional)
  - Videos: writes QuickTime creation_time & ISO6709 GPS metadata

Usage examples:
  # Preview actions only
  python takeout_icloud_media_cleaner.py "D:/Takeout/Google Photos" --dry-run --report "D:/report.csv"

  # Convert images & videos in place (keeps originals)
  python takeout_icloud_media_cleaner.py "D:/Takeout/Google Photos"

  # Build a clean destination tree with copies/conversions
  python takeout_icloud_media_cleaner.py \
      "~/Downloads/Takeout/Google Photos" \
      --dest "~/CleanedForiCloud" --copy-supported --purge-json --inject-json

Requirements:
  - Python 3.8+
  - Pillow: pip install pillow
  - ffmpeg available on PATH (https://ffmpeg.org/)
  - (optional) piexif for better EXIF writing: pip install piexif

Notes:
  - This script focuses on formats commonly seen in Google Takeout.
  - RAW & AVIF are reported; conversion not implemented here.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Set, Tuple

# --- Image libs ---
try: # check for pillow installation
    from PIL import Image, UnidentifiedImageError
except Exception:
    print("This script requires Pillow. Install it with: pip install pillow", file=sys.stderr)
    raise

try:
    import piexif  # Optional; improves EXIF writing
    _HAS_PIEXIF = True
except Exception:
    _HAS_PIEXIF = False

# --------------------
# Configuration sets
# --------------------
SUPPORTED_IMAGE_EXTS: Set[str] = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".gif", ".heic", ".heif"}
CANDIDATE_CONVERT_IMAGE: Set[str] = {".webp", ".bmp", ".jfif", ".ppm", ".pgm", ".pbm", ".pnm"}
RAW_IMAGE_EXTS: Set[str] = {".avif", ".arw", ".cr2", ".cr3", ".dng", ".nef", ".orf", ".raf", ".rw2", ".srw"}
IMAGE_EXTS: Set[str] = SUPPORTED_IMAGE_EXTS | CANDIDATE_CONVERT_IMAGE | RAW_IMAGE_EXTS

SUPPORTED_VIDEO_EXTS: Set[str] = {".mp4", ".mov", ".m4v"}
VIDEO_EXTS: Set[str] = SUPPORTED_VIDEO_EXTS | {".webm", ".mkv", ".avi", ".wmv", ".mpg", ".mpeg", ".3gp", ".mts", ".m2ts", ".ts", ".flv", ".divx", ".vob"}

NOISE_EXTS: Set[str] = {".json"}  # Google Takeout sidecars

# --------------
# Utilities
# --------------

def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def safe_output_path(dst: Path) -> Path:
    if not dst.exists():
        return dst
    stem, suffix = dst.stem, dst.suffix
    i = 1
    while True:
        c = dst.with_name(f"{stem} ({i}){suffix}")
        if not c.exists():
            return c
        i += 1


def preserve_timestamps(src: Path, dst: Path) -> None:
    try:
        st = src.stat()
        os.utime(dst, (st.st_atime, st.st_mtime))
    except Exception:
        pass


def copy_to_bucket(src: Path, bucket_root: Path, src_root: Path) -> Optional[str]:
    """Copy source file into a bucket folder while preserving relative structure."""
    try:
        rel = src.relative_to(src_root)
    except Exception:
        rel = Path(src.name)
    dst = safe_output_path(bucket_root / rel)
    try:
        ensure_dir(dst.parent)
        shutil.copy2(src, dst)
        return None
    except Exception as e:
        return str(e)


def is_image(path: Path) -> bool:
    return path.suffix.lower() in IMAGE_EXTS


def is_video(path: Path) -> bool:
    return path.suffix.lower() in VIDEO_EXTS


def is_supported_image(path: Path) -> bool:
    return path.suffix.lower() in SUPPORTED_IMAGE_EXTS


def is_supported_video_container(path: Path) -> bool:
    return path.suffix.lower() in SUPPORTED_VIDEO_EXTS

# --------------------
# Sidecar JSON helpers
# --------------------

def find_sidecar_json(path: Path) -> Optional[Path]:
    """Google Takeout commonly uses either 'file.jpg.json' or 'file.json'."""
    candidates = [
        path.with_suffix(path.suffix + ".json"),
        path.with_suffix(".json"),
    ]
    for c in candidates:
        if c.exists():
            return c
    return None


def parse_takeout_json(json_path: Optional[Path]) -> dict:
    if not json_path:
        return {}
    try:
        with open(json_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def extract_datetime_gps_from_json(meta: dict) -> Tuple[Optional[datetime], Optional[Tuple[float, float, Optional[float]]]]:
    """Return (capture_dt_utc, (lat, lon, alt?)) if present.
    Google JSON examples:
      - photoTakenTime: { timestamp: "1461974400", formatted: "..." }
      - geoData: { latitude, longitude, altitude }
      - geoDataExif: sometimes holds better GPS
    """
    # Date
    dt = None
    try:
        ts = None
        if isinstance(meta.get('photoTakenTime'), dict):
            ts = meta['photoTakenTime'].get('timestamp')
        if not ts and isinstance(meta.get('creationTime'), dict):
            ts = meta['creationTime'].get('timestamp')
        if ts:
            dt = datetime.fromtimestamp(int(ts), tz=timezone.utc)
    except Exception:
        dt = None

    # GPS (prefer geoDataExif if valid)
    def _gps_from(d: Optional[dict]):
        if not isinstance(d, dict):
            return None
        lat = d.get('latitude')
        lon = d.get('longitude')
        alt = d.get('altitude')
        if isinstance(lat, (int, float)) and isinstance(lon, (int, float)):
            return (float(lat), float(lon), float(alt) if isinstance(alt, (int, float)) else None)
        return None

    gps = _gps_from(meta.get('geoDataExif')) or _gps_from(meta.get('geoData'))

    return dt, gps


# --------------------
# Image conversion
# --------------------

def convert_image_to_jpeg(src: Path, dst: Path) -> Tuple[bool, Optional[str], Optional[bytes]]:
    try:
        with Image.open(src) as im:
            exif_bytes = im.info.get('exif')
            if im.mode in ("RGBA", "P", "LA"):
                from PIL import Image as PILImage
                bg = PILImage.new("RGB", im.size, (255, 255, 255))
                if im.mode == "P":
                    im = im.convert("RGBA")
                bg.paste(im, mask=im.split()[-1] if im.mode.endswith('A') else None)
                im = bg
            elif im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            ensure_dir(dst.parent)
            save_kwargs = {"quality": 95, "optimize": True}
            if exif_bytes:
                save_kwargs["exif"] = exif_bytes
            im.save(dst, format="JPEG", **save_kwargs)
        preserve_timestamps(src, dst)
        return True, None, None
    except UnidentifiedImageError:
        return False, "Unidentified/unsupported image format for Pillow", None
    except OSError as e:
        return False, f"OS error during convert: {e}", None
    except Exception as e:
        return False, f"Unexpected error: {e}", None


def inject_exif_from_json(jpeg_path: Path, meta: dict) -> Optional[str]:
    if not _HAS_PIEXIF:
        return "piexif not installed; skipping EXIF injection"
    try:
        dt, gps = extract_datetime_gps_from_json(meta)
        # Preserve existing EXIF and only patch date/GPS fields.
        exif_dict = piexif.load(str(jpeg_path))
        exif_dict.setdefault("0th", {})
        exif_dict.setdefault("Exif", {})
        exif_dict.setdefault("GPS", {})
        exif_dict.setdefault("1st", {})
        exif_dict.setdefault("thumbnail", None)
        if dt:
            dt_str = dt.astimezone(timezone.utc).strftime("%Y:%m:%d %H:%M:%S")
            exif_dict["Exif"][piexif.ExifIFD.DateTimeOriginal] = dt_str.encode('ascii')
            exif_dict["Exif"][piexif.ExifIFD.DateTimeDigitized] = dt_str.encode('ascii')
            exif_dict["0th"][piexif.ImageIFD.DateTime] = dt_str.encode('ascii')
            if hasattr(piexif.ExifIFD, "OffsetTimeOriginal"):
                exif_dict["Exif"][piexif.ExifIFD.OffsetTimeOriginal] = b"+00:00"
            if hasattr(piexif.ExifIFD, "OffsetTimeDigitized"):
                exif_dict["Exif"][piexif.ExifIFD.OffsetTimeDigitized] = b"+00:00"
        if gps:
            lat, lon, alt = gps
            def _deg_to_dms_rational(deg):
                d = int(abs(deg))
                m = int((abs(deg) - d) * 60)
                s = round((abs(deg) - d - m/60) * 3600 * 1000)
                return ((d,1), (m,1), (s,1000))
            exif_dict["GPS"][piexif.GPSIFD.GPSLatitudeRef] = b'N' if lat >= 0 else b'S'
            exif_dict["GPS"][piexif.GPSIFD.GPSLatitude] = _deg_to_dms_rational(lat)
            exif_dict["GPS"][piexif.GPSIFD.GPSLongitudeRef] = b'E' if lon >= 0 else b'W'
            exif_dict["GPS"][piexif.GPSIFD.GPSLongitude] = _deg_to_dms_rational(lon)
            if alt is not None:
                exif_dict["GPS"][piexif.GPSIFD.GPSAltitude] = (int(abs(alt*100)), 100)
                exif_dict["GPS"][piexif.GPSIFD.GPSAltitudeRef] = 0 if alt >= 0 else 1
        exif_bytes = piexif.dump(exif_dict)
        piexif.insert(exif_bytes, str(jpeg_path))
        return None
    except Exception as e:
        return f"EXIF injection error: {e}"

# --------------------
# Video conversion via ffmpeg
# --------------------

def resolve_ffmpeg_executable() -> Optional[str]:
    env_override = os.environ.get("TAKEOUT_FFMPEG")
    if env_override:
        p = Path(env_override).expanduser()
        if p.is_file() and os.access(str(p), os.X_OK):
            return str(p)

    discovered = shutil.which("ffmpeg")
    if discovered:
        return discovered

    for candidate in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def have_ffmpeg() -> bool:
    ffmpeg_exe = resolve_ffmpeg_executable()
    if not ffmpeg_exe:
        return False
    try:
        subprocess.run([ffmpeg_exe, "-version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return True
    except Exception:
        return False


def iso6709_from_gps(lat: float, lon: float, alt: Optional[float]) -> str:
    # ISO 6709 for QuickTime expects like "+37.785833-122.406417+000.000/"
    def s(v):
        return ("+" if v >= 0 else "-") + f"{abs(v):.6f}"
    alt_part = f"{alt:+.3f}" if isinstance(alt, (int,float)) else "+000.000"
    return f"{s(lat)}{s(lon)}{alt_part}/"


def build_ffmpeg_cmd(src: Path, dst: Path, creation_dt: Optional[datetime], gps: Optional[Tuple[float,float,Optional[float]]],
                     crf: int, preset: str, faststart: bool) -> list:
    args = [
        resolve_ffmpeg_executable() or "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(src),
        "-map_metadata", "0",
        "-c:v", "libx264", "-crf", str(crf), "-preset", preset,
        "-c:a", "aac", "-b:a", "192k",
    ]
    if faststart:
        args += ["-movflags", "+faststart"]
    # Metadata injection
    if creation_dt:
        # Use UTC ISO8601
        args += ["-metadata", f"creation_time={creation_dt.astimezone(timezone.utc).isoformat()}"]
    if gps:
        lat, lon, alt = gps
        args += ["-metadata", f"com.apple.quicktime.location.ISO6709={iso6709_from_gps(lat, lon, alt)}"]
    args += [str(dst)]
    return args


def build_ffmpeg_metadata_copy_cmd(src: Path, dst: Path, creation_dt: Optional[datetime],
                                   gps: Optional[Tuple[float,float,Optional[float]]],
                                   faststart: bool) -> list:
    args = [
        resolve_ffmpeg_executable() or "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(src),
        "-map", "0",
        "-map_metadata", "0",
        "-c", "copy",
    ]
    if faststart and src.suffix.lower() in {".mp4", ".mov", ".m4v"}:
        args += ["-movflags", "+faststart"]
    if creation_dt:
        args += ["-metadata", f"creation_time={creation_dt.astimezone(timezone.utc).isoformat()}"]
    if gps:
        lat, lon, alt = gps
        args += ["-metadata", f"com.apple.quicktime.location.ISO6709={iso6709_from_gps(lat, lon, alt)}"]
    args += [str(dst)]
    return args


def inject_video_metadata_in_place(path: Path, meta_json: dict, faststart: bool) -> Tuple[bool, Optional[str]]:
    creation_dt, gps = extract_datetime_gps_from_json(meta_json)
    if not creation_dt and not gps:
        return True, None
    tmp_out = safe_output_path(path.with_name(f"{path.stem}.metadata_tmp{path.suffix}"))
    cmd = build_ffmpeg_metadata_copy_cmd(path, tmp_out, creation_dt, gps, faststart)
    try:
        subprocess.run(cmd, check=True)
        os.replace(tmp_out, path)
        return True, None
    except subprocess.CalledProcessError as e:
        if tmp_out.exists():
            try:
                tmp_out.unlink()
            except Exception:
                pass
        return False, f"ffmpeg metadata copy failed with exit code {e.returncode}"
    except Exception as e:
        if tmp_out.exists():
            try:
                tmp_out.unlink()
            except Exception:
                pass
        return False, f"video metadata injection error: {e}"


def convert_video_to_mp4(src: Path, dst: Path, meta_json: Optional[dict], crf: int, preset: str, faststart: bool) -> Tuple[bool, Optional[str]]:
    creation_dt = None
    gps = None
    if meta_json:
        creation_dt, gps = extract_datetime_gps_from_json(meta_json)
    try:
        ensure_dir(dst.parent)
        cmd = build_ffmpeg_cmd(src, dst, creation_dt, gps, crf, preset, faststart)
        subprocess.run(cmd, check=True)
        preserve_timestamps(src, dst)
        return True, None
    except subprocess.CalledProcessError as e:
        return False, f"ffmpeg failed with exit code {e.returncode}"
    except FileNotFoundError:
        return False, "ffmpeg not found on PATH"
    except Exception as e:
        return False, f"Unexpected video convert error: {e}"

# --------------------
# Main processing
# --------------------

def process_tree(
    src_root: Path,
    dest_root: Optional[Path],
    delete_original: bool,
    copy_supported: bool,
    dry_run: bool,
    purge_json: bool,
    inject_json: bool,
    report_path: Optional[Path],
    video_crf: int,
    video_preset: str,
    video_faststart: bool,
) -> None:
    total = 0
    supported = 0
    converted = 0
    failed = 0
    skipped = 0
    json_removed = 0
    failed_bucket_count = 0
    skipped_bucket_count = 0

    report_lines = ["status,type,source_path,action_path,note"] if report_path else None
    bucket_root_base = dest_root if dest_root else src_root
    failed_bucket = bucket_root_base / "_failed_media"
    skipped_bucket = bucket_root_base / "_skipped_media"

    ffmpeg_available = have_ffmpeg()
    if not ffmpeg_available:
        print("Note: ffmpeg not found on PATH. Video conversion will be skipped.")
    else:
        print(f"ffmpeg detected at: {resolve_ffmpeg_executable()}")
    json_candidates_for_purge: List[Path] = []

    for path in src_root.rglob('*'):
        if path.is_dir():
            continue
        total += 1
        ext = path.suffix.lower()

        # Purge JSON sidecars if requested
        if purge_json and ext in NOISE_EXTS:
            # Defer deletion until after conversions/injection are complete.
            json_candidates_for_purge.append(path)
            note = "would remove JSON (deferred)" if dry_run else "queued JSON for removal"
            if report_lines is not None:
                report_lines.append(f"json,json,{path},,{note}")
            continue

        # Images
        if is_image(path):
            rel = path.relative_to(src_root)
            if is_supported_image(path):
                supported += 1
                out_path: Optional[Path] = None
                if dest_root and copy_supported:
                    out_path = dest_root / rel
                    note = f"would copy supported to {out_path}" if dry_run else "copied supported"
                    if not dry_run:
                        ensure_dir(out_path.parent)
                        shutil.copy2(path, out_path)
                else:
                    note = "left as is"

                target_for_injection = out_path if out_path is not None else path
                if inject_json and target_for_injection.suffix.lower() in {".jpg", ".jpeg"}:
                    sidecar = find_sidecar_json(path)
                    if sidecar and not dry_run:
                        meta = parse_takeout_json(sidecar)
                        inj_err = inject_exif_from_json(target_for_injection, meta)
                        if inj_err:
                            note += f"; JSON inject: {inj_err}"
                        else:
                            note += "; JSON date/GPS injected"
                    elif sidecar and dry_run:
                        note += "; would inject JSON date/GPS"
                    else:
                        note += "; no sidecar JSON found"
                elif inject_json:
                    note += "; JSON injection only supported for JPEG/JPG in supported-image path"
#places failed or skipped media in seperate folder
                if not dry_run:
                    bucket_err = copy_to_bucket(path, skipped_bucket, src_root)
                    if bucket_err:
                        note += f"; skipped-bucket copy failed: {bucket_err}"
                    else:
                        skipped_bucket_count += 1

                if report_lines is not None:
                    report_lines.append(f"supported,image,{path},{out_path or ''},{note}")
                continue

            # Convert image
            out_rel = rel.with_suffix('.jpg')
            out_path = (dest_root / out_rel) if dest_root else path.with_suffix('.jpg')
            out_path = safe_output_path(out_path)

            if dry_run:
                converted += 1
                if report_lines is not None:
                    report_lines.append(f"convert,image,{path},{out_path},would convert to JPEG")
                continue

            ok, err, _ = convert_image_to_jpeg(path, out_path)
            note = "converted to JPEG" if ok else (err or "failed")

            # Optional EXIF injection from sidecar JSON
            if ok and inject_json:
                sidecar = find_sidecar_json(path)
                if sidecar:
                    meta = parse_takeout_json(sidecar)
                    inj_err = inject_exif_from_json(out_path, meta)
                    if inj_err:
                        note += f"; JSON inject: {inj_err}"
                    else:
                        note += "; JSON date/GPS injected"

            if ok and delete_original:
                try:
                    path.unlink()
                    note += "; original deleted"
                except Exception as e:
                    note += f"; failed to delete original: {e}"

            if ok:
                converted += 1
            else:
                failed += 1
                if not dry_run:
                    bucket_err = copy_to_bucket(path, failed_bucket, src_root)
                    if bucket_err:
                        note += f"; failed-bucket copy failed: {bucket_err}"
                    else:
                        failed_bucket_count += 1
            if report_lines is not None:
                report_lines.append(f"{'converted' if ok else 'failed'},image,{path},{out_path},{note}")
            continue

        # Videos
        if is_video(path):
            rel = path.relative_to(src_root)
            # Treat only container as 'supported'; we don't probe codecs
            if is_supported_video_container(path) and not dest_root and not inject_json:
                supported += 1
                note = "left as is (container supported)"
                if not dry_run:
                    bucket_err = copy_to_bucket(path, skipped_bucket, src_root)
                    if bucket_err:
                        note += f"; skipped-bucket copy failed: {bucket_err}"
                    else:
                        skipped_bucket_count += 1
                if report_lines is not None:
                    report_lines.append(f"supported,video,{path},,{note}")
                continue
            if is_supported_video_container(path) and not dest_root and inject_json:
                supported += 1
                note = "left as is (container supported)"
                if dry_run:
                    note += "; would inject JSON metadata"
                    if report_lines is not None:
                        report_lines.append(f"supported,video,{path},,{note}")
                    continue

                sidecar = find_sidecar_json(path)
                if sidecar and ffmpeg_available:
                    meta = parse_takeout_json(sidecar)
                    ok, err = inject_video_metadata_in_place(path, meta, video_faststart)
                    if ok:
                        note += "; JSON date/GPS injected"
                    else:
                        note += f"; JSON inject failed: {err}"
                elif sidecar and not ffmpeg_available:
                    note += "; ffmpeg missing"
                else:
                    note += "; no sidecar JSON found"

                bucket_err = copy_to_bucket(path, skipped_bucket, src_root)
                if bucket_err:
                    note += f"; skipped-bucket copy failed: {bucket_err}"
                else:
                    skipped_bucket_count += 1

                if report_lines is not None:
                    report_lines.append(f"supported,video,{path},,{note}")
                continue

            # We will convert (or re-mux) to MP4 H.264/AAC
            out_rel = rel.with_suffix('.mp4')
            out_path = (dest_root / out_rel) if dest_root else path.with_suffix('.mp4')
            out_path = safe_output_path(out_path)

            if dry_run:
                converted += 1
                if report_lines is not None:
                    report_lines.append(f"convert,video,{path},{out_path},would convert to MP4 (H.264/AAC)")
                continue

            meta = parse_takeout_json(find_sidecar_json(path)) if inject_json else None
            ok, err = (False, "ffmpeg missing")
            if ffmpeg_available:
                ok, err = convert_video_to_mp4(path, out_path, meta, video_crf, video_preset, video_faststart)
            note = "converted to MP4" if ok else (err or "failed")

            if ok and delete_original:
                try:
                    path.unlink()
                    note += "; original deleted"
                except Exception as e:
                    note += f"; failed to delete original: {e}"

            if ok:
                converted += 1
            else:
                failed += 1
                if not dry_run:
                    bucket_err = copy_to_bucket(path, failed_bucket, src_root)
                    if bucket_err:
                        note += f"; failed-bucket copy failed: {bucket_err}"
                    else:
                        failed_bucket_count += 1
            if report_lines is not None:
                report_lines.append(f"{'converted' if ok else 'failed'},video,{path},{out_path},{note}")
            continue

        # Not image/video candidate
        skipped += 1
        if report_lines is not None:
            report_lines.append(f"skipped,other,{path},,not image/video candidate")

    # Remove sidecars only after all metadata injection work has finished.
    if purge_json:
        for json_path in json_candidates_for_purge:
            json_removed += 1
            if dry_run:
                continue
            try:
                json_path.unlink()
            except Exception as e:
                if report_lines is not None:
                    report_lines.append(f"failed,json,{json_path},,failed to remove JSON: {e}")

    # Report writing
    if report_path:
        ensure_dir(report_path.parent)
        with open(report_path, 'w', encoding='utf-8') as f:
            f.write("\n".join(report_lines or []))

    # Summary
    print("\n=== Takeout → iCloud Media Cleaner Summary ===")
    print(f"Scanned:       {total}")
    print(f"Supported:     {supported}")
    print(f"Converted:     {converted}")
    print(f"Failed:        {failed}")
    print(f"Skipped:       {skipped}")
    print(f"Failed bucket: {failed_bucket_count} -> {failed_bucket}")
    print(f"Skipped bucket:{skipped_bucket_count} -> {skipped_bucket}")
    if purge_json:
        print(f"JSON removed:  {json_removed}")
    if report_path:
        print(f"Report:        {report_path}")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Find unsupported Google Takeout photos/videos and convert them for iCloud Photos.")
    p.add_argument("source", type=str, help="Path to the Google Takeout 'Google Photos' root folder")
    p.add_argument("--dest", type=str, default=None, help="Destination root to mirror outputs. If omitted, convert next to originals.")
    p.add_argument("--delete-original", action="store_true", help="After successful conversion, delete the original file.")
    p.add_argument("--copy-supported", action="store_true", help="When --dest is used, also copy files already supported by iCloud.")
    p.add_argument("--dry-run", action="store_true", help="Plan actions without writing files.")
    p.add_argument("--purge-json", action="store_true", help="Remove Takeout .json sidecar files encountered during the scan.")
    p.add_argument("--inject-json", action="store_true", help="Use Takeout JSON to inject capture date and GPS into converted images/videos.")
    p.add_argument("--report", type=str, default=None, help="Write a CSV report with per‑file actions and outcomes.")

    # Video encoding controls
    p.add_argument("--video-crf", type=int, default=20, help="Quality for H.264 (lower=better). Default 20")
    p.add_argument("--video-preset", type=str, default="veryfast", help="x264 preset (ultrafast..placebo). Default veryfast")
    p.add_argument("--no-faststart", action="store_true", help="Disable +faststart (improves streaming compatibility)")

    args = p.parse_args(argv)

    src_root = Path(os.path.expanduser(args.source)).resolve()
    dest_root = Path(os.path.expanduser(args.dest)).resolve() if args.dest else None
    report_path = Path(os.path.expanduser(args.report)).resolve() if args.report else None

    if not src_root.exists():
        print(f"Source path does not exist: {src_root}", file=sys.stderr)
        return 2

    if dest_root:
        ensure_dir(dest_root)

    process_tree(
        src_root=src_root,
        dest_root=dest_root,
        delete_original=args.delete_original,
        copy_supported=args.copy_supported,
        dry_run=args.dry_run,
        purge_json=args.purge_json,
        inject_json=args.inject_json,
        report_path=report_path,
        video_crf=args.video_crf,
        video_preset=args.video_preset,
        video_faststart=not args.no_faststart,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
