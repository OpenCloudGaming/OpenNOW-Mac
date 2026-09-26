import Foundation

extension NvstBifrostFreeTransport {
    /// The live meter and the "your microphone went away" notice. Both originate on the render thread,
    /// so both hop to the main actor; the level is throttled to 20 Hz at the device.
    func installMicrophoneHandlers(_ bundle: NvstNativeBundle) {
        bundle.onMicrophoneLevel = { [weak self] level in
            Task {
                guard let self else { return }
                // The hop is the actor's: reading the handler and calling it are both isolated, and
                // the handler itself is @MainActor. Nothing here blocks the render thread.
                await self.microphoneLevelHandler?(level)
            }
        }
        // "Default Device" is the fallback's name everywhere else in the app (the picker's synthetic
        // first row), so the message says the same thing the dropdown label will.
        bundle.onMicrophoneDeviceFallback = { [weak self] _ in
            Task {
                guard let self else { return }
                await self.microphoneFallbackHandler?("Microphone unavailable \u{2014} using Default Device.")
            }
        }
        bundle.onMicrophoneDeviceListChange = { [weak self] in
            Task {
                guard let self else { return }
                await self.microphoneDeviceListHandler?()
            }
        }
    }

    /// Wires the bundle's channel callbacks back into the transport actor.
    func installBundleHandlers(_ bundle: NvstNativeBundle,
                               sender: NvstFeedbackSender,
                               logger: (@Sendable (String) -> Void)?) {
        bundleGeneration &+= 1
        let generation = bundleGeneration
        installBundleNotificationHandlers(bundle, generation: generation)
        bundle.onRemoteAudio = { [weak self] count in
            logger?("NVST bundle seat offered \(count) audio track(s)")
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.noteRemoteAudio(trackCount: count)
                }
            }
        }
        // Straight to the recorder, no actor hop: this runs on the CoreAudio render thread, where
        // waiting on anything is a priority inversion. The recorder copies and returns.
        let recorder = self.recorder
        let replayBuffer = self.replayBuffer
        let nativeBroadcaster = self.remoteCoOpNativeBroadcaster
        // The browser egress rides the same audio tap: it packetizes the same PCM the native guests
        // get, so a browser guest hears the game without a second lossy encode.
        let browserEgress = self.remoteCoOpBrowserEgress
        bundle.onGameAudioFrame = { audioBufferList, frameCount, sampleRate, channels in
            recorder.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            replayBuffer.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            nativeBroadcaster.forwardAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            browserEgress?.forwardAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
        }
        installMicrophoneHandlers(bundle)
        bundle.onPartiallyReliableControlOpen = { [weak self] in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.startQosFeedback()
                }
            }
        }
        bundle.onControlChannelOpen = { [weak self] in
            // The seat starts its 10 s client-timeout the moment the SCTP association is up, so the
            // first pingBackAck gets its own task rather than queueing behind the state announce.
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.startControlKeepAlive()
                }
            }
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.announceClientState()
                }
            }
        }
        bundle.onFeedbackChannelOpen = { [weak self] in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.logger?("NVST feedback channel open; starting receiver reports")
                    sender.start()
                    transport.adoptFeedbackSender(sender)
                    // Normally already punching since the ANNOUNCE-ready hook; idempotent.
                    transport.beginVideoHolePunch()
                }
            }
        }
    }

    private func installBundleNotificationHandlers(_ bundle: NvstNativeBundle, generation: UInt64) {
        bundle.onInputProtocolNegotiated = { [weak self] version in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.inputDidNegotiate(version)
                }
            }
        }
        bundle.onRemoteCursor = { [weak self] cursor in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleRemoteCursor(cursor)
                }
            }
        }
        bundle.onSeatStats = { [weak self] stats in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.recordSeatStats(stats)
                }
            }
        }
        bundle.onHapticEvents = { [weak self] events in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleHapticEvents(events)
                }
            }
        }
        bundle.onHdrMode = { [weak self] notification in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleHdrMode(notification)
                }
            }
        }
        bundle.onSeatTermination = { [weak self] termination in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleSeatTermination(termination)
                }
            }
        }
        bundle.onSessionLimitUpdate = { [weak self] update in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleSessionLimitUpdate(update)
                }
            }
        }
    }
}
