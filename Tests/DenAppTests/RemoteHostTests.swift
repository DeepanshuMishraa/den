import Foundation
import Testing
@testable import DenApp

@Suite struct RemoteHostTests {
    private struct Destination: Equatable {
        let address: String
        var user: String?
        var port: UInt16?
    }

    private func parsed(_ text: String) -> Destination? {
        RemoteHost.parse(text).map { Destination(address: $0.address, user: $0.user, port: $0.port) }
    }

    @Test func readsAddressUserAndPort() {
        #expect(parsed("hill.hamster-dinosaur.ts.net") == Destination(address: "hill.hamster-dinosaur.ts.net", user: nil, port: nil))
        #expect(parsed("root@100.64.0.7") == Destination(address: "100.64.0.7", user: "root", port: nil))
        #expect(parsed("me@box:2222") == Destination(address: "box", user: "me", port: 2222))
        #expect(parsed("me@[fe80::1]:2200") == Destination(address: "fe80::1", user: "me", port: 2200))
        #expect(parsed("fe80::1") == Destination(address: "fe80::1", user: nil, port: nil))
    }

    @Test func toleratesPastedSchemesAndPort22() {
        #expect(parsed("https://hill.tailnet.ts.net/") == Destination(address: "hill.tailnet.ts.net", user: nil, port: nil))
        #expect(parsed("ssh://me@box:22") == Destination(address: "box", user: "me", port: nil))
    }

    @Test func rejectsWhatIsNotAHost() {
        #expect(RemoteHost.parse("") == nil)
        #expect(RemoteHost.parse("@box") == nil)
        #expect(RemoteHost.parse("box:ssh") == nil)
        #expect(RemoteHost.parse("two words") == nil)
        #expect(RemoteHost.parse("box/path") == nil)
    }

    @Test func sameDestinationIgnoresCaseAndDefaultPort() {
        let a = RemoteHost(id: UUID(), address: "Box.local", user: "me", port: nil)
        let b = RemoteHost(id: UUID(), address: "box.local", user: "me", port: 22)
        #expect(a.sameDestination(as: b))
        #expect(!a.sameDestination(as: RemoteHost(id: UUID(), address: "box.local", user: "root", port: nil)))
    }
}

@Suite struct RemoteSetupTests {
    @Test func readsTheProbeAfterBanners() {
        let output = "Welcome to Ubuntu\nLinux x86_64\n9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08\n"
        #expect(RemoteSetup.parseProbe(output) == .init(os: "Linux", arch: "x86_64", installedHash: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"))
        #expect(RemoteSetup.parseProbe("Linux aarch64\nnone\n") == .init(os: "Linux", arch: "aarch64", installedHash: nil))
        #expect(RemoteSetup.parseProbe("Darwin arm64\nnone") == .init(os: "Darwin", arch: "arm64", installedHash: nil))
        #expect(RemoteSetup.parseProbe("garbage") == nil)
    }

    @Test func normalizesArchitectures() {
        #expect(RemoteSetup.normalize(arch: "amd64", os: "Linux") == "x86_64")
        #expect(RemoteSetup.normalize(arch: "arm64", os: "Linux") == "aarch64")
        #expect(RemoteSetup.normalize(arch: "aarch64", os: "Darwin") == "arm64")
    }

    @Test func remoteCommandsHaveNoNestedSingleQuotes() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample den@mac"
        for command in [RemoteSetup.probeCommand, RemoteSetup.installCommand, RemoteSetup.streamCommand, RemoteSetup.authorizeCommand(publicKey: key)] {
            #expect(command.hasPrefix("sh -c '") && command.hasSuffix("'"))
            #expect(command.dropFirst(7).dropLast().contains("'") == false)
        }
    }
}

@Suite struct SSHFailureTests {
    @Test func classifiesSSHErrors() {
        #expect(SSH.classify(status: 255, stderr: "me@box: Permission denied (publickey,password).") == .authentication("me@box: Permission denied (publickey,password)."))
        #expect(SSH.classify(status: 255, stderr: "ssh: connect to host box port 22: Connection refused") == .unreachable("ssh: connect to host box port 22: Connection refused"))
        #expect(SSH.classify(status: 255, stderr: "ssh: Could not resolve hostname nope: nodename nor servname provided") == .unreachable("ssh: Could not resolve hostname nope: nodename nor servname provided"))
        if case .hostKeyChanged = SSH.classify(status: 255, stderr: "@@@\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.") {} else {
            Issue.record("changed host key not detected")
        }
        #expect(SSH.classify(status: 1, stderr: "mv: cannot move") == .remote(status: 1, "mv: cannot move"))
    }

    @Test func dropsKnownHostsNoise() {
        let stderr = "Warning: Permanently added 'box' (ED25519) to the list of known hosts.\nme@box: Permission denied (password)."
        #expect(SSH.classify(status: 255, stderr: stderr) == .authentication("me@box: Permission denied (password)."))
    }
}
