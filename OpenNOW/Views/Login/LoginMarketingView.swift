//
//  LoginMarketingView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Combine
import SwiftUI

struct LoginMarketingView: View {
    @ObservedObject var viewModel: LoginViewModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GFNHeroArtwork()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .ignoresSafeArea()
    }
}
