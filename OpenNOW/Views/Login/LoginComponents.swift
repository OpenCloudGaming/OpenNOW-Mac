//
//  LoginComponents.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import SwiftUI

struct LoginBackdrop: View {
    var body: some View {
        Color.black
        .ignoresSafeArea()
    }
}

struct VendorResourceImage: View {
    let name: String
    let fileExtension: String

    var body: some View {
        if let image = Self.loadImage(name: name, fileExtension: fileExtension) {
            Image(nsImage: image)
                .resizable()
        } else {
            Color.black
        }
    }

    private static func loadImage(name: String, fileExtension: String) -> NSImage? {
        for subdirectory in ["NVIDIA", "Resources/NVIDIA", nil] as [String?] {
            let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
            if let url, let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

struct GFNHeroArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let backgroundBaseHeight = max(proxy.size.height, proxy.size.width * 0.5)
            let gridHeight = 1.66 * backgroundBaseHeight
            let gridWidth = 2.5 * backgroundBaseHeight
            let imageHeight = 0.22 * backgroundBaseHeight
            let rowOffset = 0.1 * backgroundBaseHeight

            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.286, green: 0.286, blue: 0.286), .black],
                    center: UnitPoint(x: 0.65, y: 0.25),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.75
                )

                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { column in
                                VendorResourceImage(name: "LoginWallFallbackTile", fileExtension: "png")
                                    .scaledToFit()
                                    .frame(height: imageHeight)
                                    .opacity(0.5)

                                if column < 5 {
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .frame(width: gridWidth)
                        .offset(x: row.isMultiple(of: 2) ? rowOffset : -rowOffset)

                        if row < 5 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(width: gridWidth, height: gridHeight)
                .rotationEffect(.degrees(-15))
                .position(x: proxy.size.width - (gridWidth / 2) + (0.12 * backgroundBaseHeight), y: proxy.size.height / 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 42

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let fallback = name.first.map(String.init) ?? "O"
        let value = letters.isEmpty ? fallback : String(letters)
        return value.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Color.openNowGreen, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}
