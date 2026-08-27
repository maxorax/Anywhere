//
//  AboutView.swift
//  Turn
//
//  Created by NodePassProject on 8/27/26.
//

import SwiftUI

struct AboutView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MTurn"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .padding(.bottom, 2)
                    Text(verbatim: appName)
                        .font(.title2.weight(.semibold))
                    Text("Version \(version) (\(build))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section("Purpose") {
                Text("This app was created for educational purposes — to demonstrate how network tunnels work.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
