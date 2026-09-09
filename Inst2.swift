//
//  Inst2.swift
//  Takeout Coverter
//
//  Created by Lex Mackey on 2/23/26.
//

import SwiftUI

struct Inst2: View {
    var body: some View {
        NavigationStack {
            VStack { //sticks title
                Text("How to Use: ")
                    .font(.system(size: 50))
                    .font(Font.largeTitle.bold())
                    ScrollView { //scrolls on smaller displays properly
                            Section(header: Text("Homebrew Setup:")) {
                                Text("  - Setup up homebrew on your mac following these instructions at the link: https://brew.sh/")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("  - Install ffmpeg with homebrew with the code below:")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("$  brew install ffmpeg")
                                        .font(.system(.body, design: .monospaced))
                                        .background(Color(.sRGB, white: 0.1, opacity: 1.0))
                                        .foregroundColor(.green)
                                        .cornerRadius(20)
                                }
                            }
                            
                            Section(header: Text("General Problems:")) {
                                Text("  - If you get an error when trying to install ffmpeg, try this: sudo dnf install ffmpeg")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("  - If you encounter an error report here: (link)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } //Vstack
            }
        }
    }

#Preview {
    Inst2()
}
// versao velha
//Text("How to Use")
//    .font(.system(size: 50))
//    .padding(20)
//
//Text("Homebrew Setup:")
//    .frame(maxWidth: .infinity, alignment: .leading)
//    .font(.system(size: 20, weight: .bold))
//
//Text("  - Setup up homebrew on your mac following these instructions at the link: https://brew.sh/")
//    .frame(maxWidth: .infinity, alignment: .leading)
//
//Text("  - Install ffmpeg with homebrew: brew install ffmpeg")
//    .frame(maxWidth: .infinity, alignment: .leading)
//
//Text("General Problems: ")
//    .frame(maxWidth: .infinity, alignment: .leading)
//    .font(.system(size: 20, weight: .bold))
//
//Text("  - If you get an error when trying to install ffmpeg, try this: sudo dnf install ffmpeg")
//    .frame(maxWidth: .infinity, alignment: .leading)
//
//Text("If there are any bugs report them here: (link)")
