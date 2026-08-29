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
    /// The relay's own report, polled by the model that also watches for
    /// captchas — the relay runs in the tunnel process, so this is the only way
    /// the app learns anything about it.
    @State private var relay = TurnCaptchaModel.shared

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
                if let live = relay.lastState.activeStreams, relay.lastState.running {
                    LabeledContent("Active") {
                        Text(verbatim: "\(live) / \(relay.lastState.streams ?? Int(streams))")
                            .font(.body.monospacedDigit().weight(.medium))
                            .foregroundStyle(live == 0 ? .secondary : .primary)
                    }
                }
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
                Text("Each stream joins the VK call as a separate participant, and the more of them the more traffic they carry. All of them share one trip for credentials, so raising the count costs no extra captcha — but VK caps how many streams one trip is good for, and anything past that cap never comes up. While the relay is running, Active shows how many of them are actually carrying traffic. Default is 10.")
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
