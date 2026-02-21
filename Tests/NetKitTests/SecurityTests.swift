import Foundation
import Testing
@testable import NetKit

// MARK: - SecurityPolicy Tests

@Suite("SecurityPolicy Tests")
struct SecurityPolicyTests {
    @Test("Public key pinning creates policy with correct mode")
    func publicKeyPinningMode() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com"],
            publicKeys: [keyData]
        )

        #expect(policy.mode == .publicKey)
    }

    @Test("Public key pinning stores hosts correctly")
    func publicKeyPinningHosts() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com", "cdn.example.com"],
            publicKeys: [keyData]
        )

        #expect(policy.pinnedHosts.contains("api.example.com"))
        #expect(policy.pinnedHosts.contains("cdn.example.com"))
        #expect(policy.pinnedHosts.count == 2)
    }

    @Test("Public key pinning stores keys correctly")
    func publicKeyPinningKeys() {
        let primaryKey: Data = Data([0x01, 0x02, 0x03])
        let fallbackKey: Data = Data([0x04, 0x05, 0x06])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [primaryKey],
            fallbackKeys: [fallbackKey]
        )

        #expect(policy.pinnedItems.count == 1)
        #expect(policy.pinnedItems.first == primaryKey)
        #expect(policy.fallbackItems.count == 1)
        #expect(policy.fallbackItems.first == fallbackKey)
    }

    @Test("Public key pinning validates certificate chain by default")
    func publicKeyPinningValidatesChain() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )

        #expect(policy.validateCertificateChain == true)
    }

    @Test("Public key pinning can disable chain validation")
    func publicKeyPinningDisableChainValidation() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData],
            validateChain: false
        )

        #expect(policy.validateCertificateChain == false)
    }

    @Test("Certificate pinning creates policy with correct mode")
    func certificatePinningMode() {
        let certData: Data = Data([0x04, 0x05, 0x06])
        let policy: SecurityPolicy = SecurityPolicy.certificatePinning(
            certificates: [certData]
        )

        #expect(policy.mode == .certificate)
    }

    @Test("Certificate pinning stores certificates correctly")
    func certificatePinningCerts() {
        let primaryCert: Data = Data([0x01, 0x02, 0x03])
        let fallbackCert: Data = Data([0x04, 0x05, 0x06])
        let policy: SecurityPolicy = SecurityPolicy.certificatePinning(
            certificates: [primaryCert],
            fallbackCertificates: [fallbackCert]
        )

        #expect(policy.pinnedItems.count == 1)
        #expect(policy.pinnedItems.first == primaryCert)
        #expect(policy.fallbackItems.count == 1)
        #expect(policy.fallbackItems.first == fallbackCert)
    }

    @Test("Certificate pinning always validates chain")
    func certificatePinningAlwaysValidatesChain() {
        let certData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.certificatePinning(
            certificates: [certData]
        )

        #expect(policy.validateCertificateChain == true)
    }

    @Test("Default failure action is reject")
    func defaultFailureActionIsReject() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )

        #expect(policy.failureAction == .reject)
    }

    @Test("Failure action can be changed with modifier")
    func failureActionModifier() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        ).withFailureAction(.allowWithWarning)

        #expect(policy.failureAction == .allowWithWarning)
    }

    @Test("shouldPin returns true for pinned host")
    func shouldPinForPinnedHost() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com"],
            publicKeys: [keyData]
        )

        #expect(policy.shouldPin(host: "api.example.com") == true)
    }

    @Test("shouldPin returns false for non-pinned host")
    func shouldPinForNonPinnedHost() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com"],
            publicKeys: [keyData]
        )

        #expect(policy.shouldPin(host: "other.example.com") == false)
    }

    @Test("shouldPin returns true for all hosts when pinnedHosts is empty")
    func shouldPinForAllHostsWhenEmpty() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )

        #expect(policy.shouldPin(host: "any.example.com") == true)
        #expect(policy.shouldPin(host: "another.domain.com") == true)
    }

    @Test("allPinnedItems combines primary and fallback items")
    func allPinnedItemsCombines() {
        let primary: Data = Data([0x01])
        let fallback: Data = Data([0x02])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [primary],
            fallbackKeys: [fallback]
        )

        #expect(policy.allPinnedItems.count == 2)
        #expect(policy.allPinnedItems.contains(primary))
        #expect(policy.allPinnedItems.contains(fallback))
    }
}

// MARK: - PinnedKey Tests

@Suite("PinnedKey Tests")
struct PinnedKeyTests {
    @Test("DER key matches exact data")
    func derKeyMatchesExactData() {
        let keyData: Data = Data([0x01, 0x02, 0x03, 0x04])
        let pinnedKey: PinnedKey = .der(keyData)

        #expect(pinnedKey.matches(publicKeyData: keyData) == true)
        #expect(pinnedKey.matches(publicKeyData: Data([0x01, 0x02])) == false)
    }

    @Test("SPKI SHA256 hash matches computed hash")
    func spkiHashMatchesComputedHash() {
        let keyData: Data = Data([0x01, 0x02, 0x03, 0x04])
        let expectedHash: String = PinnedKey.computeSPKIHash(from: keyData)
        let pinnedKey: PinnedKey = .spkiSHA256(expectedHash)

        #expect(pinnedKey.matches(publicKeyData: keyData) == true)
    }

    @Test("SPKI SHA256 hash does not match different data")
    func spkiHashDoesNotMatchDifferentData() {
        let originalData: Data = Data([0x01, 0x02, 0x03, 0x04])
        let differentData: Data = Data([0x05, 0x06, 0x07, 0x08])
        let pinnedKey: PinnedKey = .spkiSHA256(PinnedKey.computeSPKIHash(from: originalData))

        #expect(pinnedKey.matches(publicKeyData: differentData) == false)
    }

    @Test("computeSPKIHash produces consistent results")
    func computeSPKIHashIsConsistent() {
        let keyData: Data = Data([0x01, 0x02, 0x03, 0x04])
        let hash1: String = PinnedKey.computeSPKIHash(from: keyData)
        let hash2: String = PinnedKey.computeSPKIHash(from: keyData)

        #expect(hash1 == hash2)
    }

    @Test("derBase64 creates key from valid base64")
    func derBase64CreatesKeyFromValidBase64() {
        let originalData: Data = Data([0x01, 0x02, 0x03, 0x04])
        let base64: String = originalData.base64EncodedString()

        let pinnedKey: PinnedKey? = PinnedKey.derBase64(base64)

        #expect(pinnedKey != nil)
        if case .der(let data) = pinnedKey {
            #expect(data == originalData)
        }
    }

    @Test("derBase64 returns nil for invalid base64")
    func derBase64ReturnsNilForInvalidBase64() {
        let pinnedKey: PinnedKey? = PinnedKey.derBase64("not-valid-base64!!!")

        #expect(pinnedKey == nil)
    }

    @Test("SecurityPolicy with PinnedKey supports SPKI hash")
    func securityPolicyWithSPKIHash() {
        let keyData: Data = Data([0x01, 0x02, 0x03, 0x04])
        let hash: String = PinnedKey.computeSPKIHash(from: keyData)

        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com"],
            keys: [.spkiSHA256(hash)],
            fallback: []
        )

        #expect(policy.pinnedKeys.count == 1)
        #expect(policy.allPinnedKeys.count == 1)
    }
}

// MARK: - SecurityError Tests

@Suite("SecurityError Tests")
struct SecurityErrorTests {
    @Test("Pinning validation failed error has correct description")
    func pinningFailedDescription() {
        let error: SecurityError = .pinningValidationFailed(host: "api.example.com")

        #expect(error.errorDescription?.contains("api.example.com") == true)
        #expect(error.errorDescription?.contains("pinning") == true)
    }

    @Test("Certificate chain invalid error has correct description")
    func chainInvalidDescription() {
        let error: SecurityError = .certificateChainInvalid(host: "api.example.com", underlyingError: nil)

        #expect(error.errorDescription?.contains("api.example.com") == true)
        #expect(error.errorDescription?.contains("chain") == true)
    }

    @Test("Public key extraction failed error has correct description")
    func publicKeyExtractionFailedDescription() {
        let error: SecurityError = .publicKeyExtractionFailed(host: "api.example.com")

        #expect(error.errorDescription?.contains("api.example.com") == true)
        #expect(error.errorDescription?.contains("public key") == true)
    }

    @Test("Pinning validation failed errors are equal for same host")
    func pinningFailedEquality() {
        let error1: SecurityError = .pinningValidationFailed(host: "api.example.com")
        let error2: SecurityError = .pinningValidationFailed(host: "api.example.com")

        #expect(error1 == error2)
    }

    @Test("Pinning validation failed errors are not equal for different hosts")
    func pinningFailedInequality() {
        let error1: SecurityError = .pinningValidationFailed(host: "api.example.com")
        let error2: SecurityError = .pinningValidationFailed(host: "other.example.com")

        #expect(error1 != error2)
    }

    @Test("Certificate chain invalid errors are equal for same host and nil error")
    func chainInvalidEqualityNilError() {
        let error1: SecurityError = .certificateChainInvalid(host: "api.example.com", underlyingError: nil)
        let error2: SecurityError = .certificateChainInvalid(host: "api.example.com", underlyingError: nil)

        #expect(error1 == error2)
    }

    @Test("Different error types are not equal")
    func differentErrorTypesNotEqual() {
        let error1: SecurityError = .pinningValidationFailed(host: "api.example.com")
        let error2: SecurityError = .publicKeyExtractionFailed(host: "api.example.com")

        #expect(error1 != error2)
    }
}

// MARK: - CertificatePinningDelegate Tests

@Suite("CertificatePinningDelegate Tests")
struct CertificatePinningDelegateTests {
    @Test("Delegate can be created with policy")
    func delegateCreation() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com"],
            publicKeys: [keyData]
        )

        let delegate: CertificatePinningDelegate = CertificatePinningDelegate(policy: policy)

        // Verify delegate is a valid URLSessionDelegate
        #expect(delegate is URLSessionDelegate)
    }

    @Test("Delegate starts with empty validated hosts")
    func delegateStartsWithEmptyValidatedHosts() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )

        let delegate: CertificatePinningDelegate = CertificatePinningDelegate(policy: policy)

        #expect(delegate.validatedHosts.isEmpty)
    }

    @Test("isHostValidated returns false for unvalidated host")
    func isHostValidatedReturnsFalseForUnvalidatedHost() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )

        let delegate: CertificatePinningDelegate = CertificatePinningDelegate(policy: policy)

        #expect(delegate.isHostValidated("api.example.com") == false)
    }
}

// MARK: - PinningSessionFactory Tests

@Suite("PinningSessionFactory Tests")
struct PinningSessionFactoryTests {
    @Test("Factory creates session with default configuration")
    func factoryCreatesSession() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )

        let session: URLSession = PinningSessionFactory.createSession(policy: policy)

        #expect(session.delegate != nil)
    }

    @Test("Factory creates session with custom configuration")
    func factoryCreatesSessionWithCustomConfig() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )
        let config: URLSessionConfiguration = URLSessionConfiguration.ephemeral

        let session: URLSession = PinningSessionFactory.createSession(
            policy: policy,
            configuration: config
        )

        #expect(session.delegate != nil)
    }

    @Test("Factory creates session with custom delegate queue")
    func factoryCreatesSessionWithDelegateQueue() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )
        let queue: OperationQueue = OperationQueue()
        queue.name = "TestQueue"

        let session: URLSession = PinningSessionFactory.createSession(
            policy: policy,
            configuration: .default,
            delegateQueue: queue
        )

        #expect(session.delegate != nil)
        #expect(session.delegateQueue.name == "TestQueue")
    }

    @Test("Factory can retrieve delegate from session")
    func factoryCanRetrieveDelegate() {
        let keyData: Data = Data([0x01, 0x02, 0x03])
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            publicKeys: [keyData]
        )

        let session: URLSession = PinningSessionFactory.createSession(policy: policy)
        let delegate: CertificatePinningDelegate? = PinningSessionFactory.delegate(for: session)

        #expect(delegate != nil)
    }

    @Test("Factory returns nil for session not created by factory")
    func factoryReturnsNilForUnknownSession() {
        let session: URLSession = URLSession(configuration: .default)
        let delegate: CertificatePinningDelegate? = PinningSessionFactory.delegate(for: session)

        #expect(delegate == nil)
    }
}
