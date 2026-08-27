//
//  TurnSettingsView.swift
//  Turn
//

import SwiftUI

/// Settings for relaying through VK Calls TURN.
///
/// The subscription already carries a relay per server and a call link to pull
/// credentials from, so nothing here is required. It exists for the two things
/// the subscription cannot know: which call the user wants to borrow, and how
/// eagerly to fall back to it.
struct TurnSettingsView: View {
    @State private var vkLink = AWCore.getTurnVKLink()
    @State private var mode = AWCore.getTurnMode()
    @State private var autoCaptcha = AWCore.getTurnAutoCaptcha()
    @State private var solver = AWCore.getTurnCaptchaSolver()
    @State private var streams = Double(AWCore.getTurnStreams())

    var body: some View {
        Form {
            Section {
                TextField(String("https://vk.com/call/join/…"), text: $vkLink, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                    .onChange(of: vkLink) { AWCore.setTurnVKLink(vkLink) }
            } header: {
                Text("VK Call Link")
            } footer: {
                Text(vkLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Leave empty to use the link from your subscription. Set your own to replace it — useful when the subscription's call is exhausted."
                     : "Your link is in use. The subscription's link is ignored while this is set.")
            }

            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(TurnMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: mode) { AWCore.setTurnMode(mode) }
            } header: {
                Text("When to Relay")
            } footer: {
                Text(mode.caption)
            }

            Section {
                LabeledContent("Streams") {
                    Text(verbatim: "\(Int(streams))")
                        .font(.body.monospacedDigit().weight(.medium))
                }
                Slider(
                    value: $streams,
                    in: Double(TurnStreamCount.minimum)...Double(TurnStreamCount.maximum),
                    step: 1
                )
                .onChange(of: streams) { AWCore.setTurnStreams(Int(streams)) }
            } header: {
                Text("Streams")
            } footer: {
                Text("Each stream joins the VK call as a separate participant, and the more of them the more traffic they carry. The first ten come up on one trip for credentials. Every further ten needs its own trip, and VK may answer that one with a captcha — until it is solved those streams stay down. Default is 10.")
            }

            Section {
                Toggle("Solve Automatically", isOn: $autoCaptcha)
                    .onChange(of: autoCaptcha) { AWCore.setTurnAutoCaptcha(autoCaptcha) }

                if autoCaptcha {
                    Picker("Solver", selection: $solver) {
                        Text(String("v2")).tag(String("v2"))
                        Text(String("v1")).tag(String("v1"))
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: solver) { AWCore.setTurnCaptchaSolver(solver) }
                }
            } header: {
                Text("VK Captcha")
            } footer: {
                Text(autoCaptcha
                     ? "The core tries the solver, then a slider, and only shows you the page if both fail."
                     : "Every captcha is shown to you straight away, with no automatic attempt.")
            }
        }
        .navigationTitle("VK TURN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Re-read on every appearance rather than trusting the value @State
            // captured when the view was first built: the extension writes to the
            // same App Group, and a stale field here reads as "my link vanished".
            vkLink = AWCore.getTurnVKLink()
            mode = AWCore.getTurnMode()
            autoCaptcha = AWCore.getTurnAutoCaptcha()
            solver = AWCore.getTurnCaptchaSolver()
            streams = Double(AWCore.getTurnStreams())
        }
    }
}
