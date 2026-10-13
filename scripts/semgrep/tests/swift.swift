// ruleid: miledge.swift.parse-inventory
import Foundation
// ruleid: miledge.swift.parse-inventory
import CryptoKit
// ruleid: miledge.swift.parse-inventory
import Security
// ruleid: miledge.swift.parse-inventory
import UIKit

func logging(secret: String) {
    // ruleid: miledge.swift.no-production-logging
    print(secret)
    // ruleid: miledge.swift.no-production-logging
    NSLog("%@", secret)
    // ruleid: miledge.swift.no-production-logging
    logger.debug("Value \(secret)")
    // ok: miledge.swift.no-production-logging
    let label = "print(secret)"
}

func defaults(secret: String) {
    // ruleid: miledge.swift.no-userdefaults-storage
    UserDefaults.standard.set(secret, forKey: "payload")
    let settings = UserDefaults.standard
    // ruleid: miledge.swift.no-userdefaults-storage
    settings.set(secret, forKey: "payload")
    let other = UserDefaults(suiteName: "synthetic")
    // ruleid: miledge.swift.no-userdefaults-storage
    other?.set(secret, forKey: "payload")
    // ok: miledge.swift.no-userdefaults-storage
    let value = UserDefaults.standard.string(forKey: "appearance")
}

func accessibility() {
    // ruleid: miledge.swift.keychain-when-unlocked
    let unsafe = kSecAttrAccessibleAfterFirstUnlock
    // ruleid: miledge.swift.keychain-when-unlocked
    let deprecated = kSecAttrAccessibleAlwaysThisDeviceOnly
    // ok: miledge.swift.keychain-when-unlocked
    let local = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    // ok: miledge.swift.keychain-when-unlocked
    let sync = kSecAttrAccessibleWhenUnlocked
}

func crypto(data: Data, key: SymmetricKey, header: Data, nonce: AES.GCM.Nonce) throws {
    // ruleid: miledge.swift.no-legacy-crypto
    let digest = Insecure.MD5.hash(data: data)
    // ok: miledge.swift.no-legacy-crypto
    let checksum = SHA256.hash(data: data)
    // ruleid: miledge.swift.no-explicit-gcm-nonce
    let explicit = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: header)
    // ruleid: miledge.swift.authenticated-envelope
    let unbound = try AES.GCM.seal(data, using: key)
    // ok: miledge.swift.authenticated-envelope, miledge.swift.no-explicit-gcm-nonce
    let authenticated = try AES.GCM.seal(data, using: key, authenticating: header)
}

func files(data: Data, url: URL, store: EncryptedBlobStore) throws {
    // ruleid: miledge.swift.no-direct-file-write
    try data.write(to: url, options: .atomic)
    // ruleid: miledge.swift.no-direct-file-write
    try "Synthetic text".write(toFile: "synthetic.txt", atomically: true, encoding: .utf8)
    // ok: miledge.swift.no-direct-file-write
    let blob = try store.write(data)
}

func networking(trust: SecTrust) {
    // ruleid: miledge.swift.no-custom-network-client
    let session = URLSession.shared
    // ruleid: miledge.swift.no-custom-network-client
    let custom = URLSession(configuration: .default)
    // ok: miledge.swift.no-custom-network-client
    let local = URL(fileURLWithPath: "synthetic.bin")
    // ruleid: miledge.swift.no-server-trust-bypass
    let credential = URLCredential(trust: trust)
    // ok: miledge.swift.no-server-trust-bypass
    completionHandler(.performDefaultHandling, nil)
}

func clipboard(secret: String, pasteboard: UIPasteboard, expiry: Date) {
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    UIPasteboard.general.string = secret
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    UIPasteboard.general.setItems([["synthetic": secret]], options: [.localOnly: true])
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    pasteboard.setItems([["synthetic": secret]], options: [.expirationDate: expiry])
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    pasteboard.setItems([["synthetic": secret]], options: [.localOnly: false, .expirationDate: expiry])
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    UIPasteboard.general.items = [["synthetic": secret]]
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    pasteboard.setItems([["synthetic": secret]])
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    pasteboard.setValue(secret, forPasteboardType: "public.utf8-plain-text")
    // ruleid: miledge.swift.no-unrestricted-ios-clipboard
    pasteboard.setData(Data(secret.utf8), forPasteboardType: "public.utf8-plain-text")
    // ok: miledge.swift.no-unrestricted-ios-clipboard
    pasteboard.setItems([["synthetic": secret]], options: [.localOnly: true, .expirationDate: expiry])
    // ok: miledge.swift.no-unrestricted-ios-clipboard
    pasteboard.setItems([], options: [.localOnly: true])
}
