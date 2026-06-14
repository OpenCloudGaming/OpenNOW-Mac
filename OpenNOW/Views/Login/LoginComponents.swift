//
//  LoginComponents.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

struct LoginBackdrop: View {
    var body: some View {
        Color.black
        .ignoresSafeArea()
    }
}

struct GFNWordmark: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.openNowGreen
                Image(systemName: "eye.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.black)
            }
            .frame(width: 36, height: 24)

            Text("GEFORCE NOW")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .tracking(0.8)
        }
    }
}

struct GFNHeroArtwork: View {
    private let columns = [
        GridItem(.fixed(150), spacing: 18),
        GridItem(.fixed(150), spacing: 18),
        GridItem(.fixed(150), spacing: 18),
        GridItem(.fixed(150), spacing: 18),
    ]

    var body: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(colors: [Color.gfnCharcoal, .black], startPoint: .topTrailing, endPoint: .bottomLeading)

            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(0..<24, id: \.self) { index in
                    GFNGameTile(index: index)
                }
            }
            .rotationEffect(.degrees(-10))
            .offset(x: 220, y: -16)
            .opacity(0.82)
            .blur(radius: 0.2)

            LinearGradient(colors: [.clear, .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct GFNGameTile: View {
    let index: Int

    private var colors: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.16, green: 0.48, blue: 0.12), Color(red: 0.02, green: 0.08, blue: 0.02)],
            [Color(red: 0.12, green: 0.20, blue: 0.34), Color(red: 0.02, green: 0.03, blue: 0.09)],
            [Color(red: 0.45, green: 0.18, blue: 0.08), Color(red: 0.10, green: 0.03, blue: 0.01)],
            [Color(red: 0.28, green: 0.28, blue: 0.30), Color(red: 0.06, green: 0.06, blue: 0.07)],
        ]
        return palettes[index % palettes.count]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: 96, height: 96)
                .offset(x: 78, y: -76)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
            Text(["RTX", "GFN", "4K", "120"][index % 4])
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.70))
                .padding(12)
        }
        .frame(width: 150, height: 210)
        .clipped()
        .overlay {
            Rectangle()
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 12)
    }
}

struct LoginStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.gfnTextTertiary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gfnPanel.opacity(0.92))
        .overlay {
            Rectangle()
                .stroke(Color.gfnStroke, lineWidth: 1)
        }
    }
}

struct LoginChecklistItem: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.openNowGreen)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }
}

struct SessionMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.openNowGreen)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
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
