import BitwardenSdk
import Combine
import Foundation

@testable import BitwardenShared

class MockVaultRepository: VaultRepository {
    // MARK: Properties

    var addCipherCiphers = [CipherView]()
    var addCipherResult: Result<Void, Error> = .success(())

    var ciphersSubject = CurrentValueSubject<[CipherListView], Error>([])
    var ciphersAutofillSubject = CurrentValueSubject<[CipherView], Error>([])
    var cipherDetailsSubject = CurrentValueSubject<CipherView?, Error>(.fixture())

    var deletedCipher = [String]()
    var deleteCipherResult: Result<Void, Error> = .success(())

    var doesActiveAccountHavePremiumCalled = false
    var doesActiveAccountHavePremiumResult: Result<Bool, Error> = .success(true)

    var fetchCipherId: String?
    var fetchCipherResult: Result<CipherView?, Error> = .success(nil)

    var fetchCipherOwnershipOptionsIncludePersonal: Bool? // swiftlint:disable:this identifier_name
    var fetchCipherOwnershipOptions = [CipherOwner]()

    var fetchCollectionsIncludeReadOnly: Bool?
    var fetchCollectionsResult: Result<[CollectionView], Error> = .success([])

    var fetchFoldersCalled = false
    var fetchFoldersResult: Result<[FolderView], Error> = .success([])

    var fetchSyncCalled = false
    var fetchSyncResult: Result<Void, Error> = .success(())

    var getActiveAccountIdResult: Result<String, StateServiceError> = .failure(.noActiveAccount)

    var getDisableAutoTotpCopyResult: Result<Bool, Error> = .success(false)

    var organizationsSubject = CurrentValueSubject<[Organization], Error>([])

    var refreshTOTPCodesResult: Result<[VaultListItem], Error> = .success([])
    var refreshedTOTPTime: Date?
    var refreshedTOTPCodes: [VaultListItem] = []
    var refreshTOTPCodeResult: Result<LoginTOTPState, Error> = .success(
        LoginTOTPState(
            authKeyModel: TOTPKeyModel(authenticatorKey: .base32Key)!
        )
    )
    var refreshedTOTPKeyConfig: TOTPKeyModel?

    var removeAccountIds = [String?]()

    var searchCipherSubject = CurrentValueSubject<[VaultListItem], Error>([])

    var shareCipherCiphers = [CipherView]()
    var shareCipherResult: Result<Void, Error> = .success(())

    var softDeletedCipher = [CipherView]()
    var softDeleteCipherResult: Result<Void, Error> = .success(())

    var timeProvider: TimeProvider = MockTimeProvider(.currentTime)

    var updateCipherCiphers = [BitwardenSdk.CipherView]()
    var updateCipherResult: Result<Void, Error> = .success(())

    var updateCipherCollectionsCiphers = [CipherView]()
    var updateCipherCollectionsResult: Result<Void, Error> = .success(())

    var validatePasswordPasswords = [String]()
    var validatePasswordResult: Result<Bool, Error> = .success(true)

    var vaultListSubject = CurrentValueSubject<[VaultListSection], Error>([])
    var vaultListGroupSubject = CurrentValueSubject<[VaultListItem], Error>([])
    var vaultListFilter: VaultFilterType?

    // MARK: Computed Properties

    var refreshedTOTPKey: String? {
        refreshedTOTPKeyConfig?.rawAuthenticatorKey
    }

    // MARK: Methods

    func addCipher(_ cipher: BitwardenSdk.CipherView) async throws {
        addCipherCiphers.append(cipher)
        try addCipherResult.get()
    }

    func cipherPublisher() async throws -> AsyncThrowingPublisher<AnyPublisher<[CipherListView], Error>> {
        ciphersSubject.eraseToAnyPublisher().values
    }

    func cipherDetailsPublisher(id _: String) async throws -> AsyncThrowingPublisher<AnyPublisher<CipherView?, Error>> {
        cipherDetailsSubject.eraseToAnyPublisher().values
    }

    func ciphersAutofillPublisher(
        uri _: String?
    ) async throws -> AsyncThrowingPublisher<AnyPublisher<[CipherView], Error>> {
        ciphersAutofillSubject.eraseToAnyPublisher().values
    }

    func deleteCipher(_ id: String) async throws {
        deletedCipher.append(id)
        try deleteCipherResult.get()
    }

    func doesActiveAccountHavePremium() async throws -> Bool {
        doesActiveAccountHavePremiumCalled = true
        return try doesActiveAccountHavePremiumResult.get()
    }

    func fetchCipher(withId id: String) async throws -> CipherView? {
        fetchCipherId = id
        return try fetchCipherResult.get()
    }

    func fetchCipherOwnershipOptions(includePersonal: Bool) async throws -> [CipherOwner] {
        fetchCipherOwnershipOptionsIncludePersonal = includePersonal
        return fetchCipherOwnershipOptions
    }

    func fetchCollections(includeReadOnly: Bool) async throws -> [CollectionView] {
        fetchCollectionsIncludeReadOnly = includeReadOnly
        return try fetchCollectionsResult.get()
    }

    func fetchFolders() async throws -> [FolderView] {
        fetchFoldersCalled = true
        return try fetchFoldersResult.get()
    }

    func fetchSync(isManualRefresh _: Bool) async throws {
        fetchSyncCalled = true
        try fetchSyncResult.get()
    }

    func getDisableAutoTotpCopy() async throws -> Bool {
        try getDisableAutoTotpCopyResult.get()
    }

    func organizationsPublisher() async throws -> AsyncThrowingPublisher<AnyPublisher<[Organization], Error>> {
        organizationsSubject.eraseToAnyPublisher().values
    }

    func refreshTOTPCode(for key: BitwardenShared.TOTPKeyModel) async throws -> BitwardenShared.LoginTOTPState {
        refreshedTOTPKeyConfig = key
        return try refreshTOTPCodeResult.get()
    }

    func refreshTOTPCodes(for items: [BitwardenShared.VaultListItem]) async throws -> [BitwardenShared.VaultListItem] {
        refreshedTOTPTime = timeProvider.presentTime
        refreshedTOTPCodes = items
        return try refreshTOTPCodesResult.get()
    }

    func remove(userId: String?) async {
        removeAccountIds.append(userId)
    }

    func searchCipherPublisher(
        searchText _: String,
        filterType _: VaultFilterType
    ) async throws -> AsyncThrowingPublisher<AnyPublisher<[VaultListItem], Error>> {
        searchCipherSubject.eraseToAnyPublisher().values
    }

    func shareCipher(_ cipher: CipherView) async throws {
        shareCipherCiphers.append(cipher)
        try shareCipherResult.get()
    }

    func softDeleteCipher(_ cipher: CipherView) async throws {
        softDeletedCipher.append(cipher)
        try softDeleteCipherResult.get()
    }

    func updateCipher(_ cipher: BitwardenSdk.CipherView) async throws {
        updateCipherCiphers.append(cipher)
        try updateCipherResult.get()
    }

    func updateCipherCollections(_ cipher: CipherView) async throws {
        updateCipherCollectionsCiphers.append(cipher)
        try updateCipherCollectionsResult.get()
    }

    func validatePassword(_ password: String) async throws -> Bool {
        validatePasswordPasswords.append(password)
        return try validatePasswordResult.get()
    }

    func vaultListPublisher(
        filter: VaultFilterType
    ) async throws -> AsyncThrowingPublisher<AnyPublisher<[VaultListSection], Error>> {
        vaultListFilter = filter
        return vaultListSubject.eraseToAnyPublisher().values
    }

    func vaultListPublisher(
        group _: BitwardenShared.VaultListGroup,
        filter _: VaultFilterType
    ) async throws -> AsyncThrowingPublisher<AnyPublisher<[VaultListItem], Error>> {
        vaultListGroupSubject.eraseToAnyPublisher().values
    }
}

// MARK: - MockTimeProvider

class MockTimeProvider {
    enum TimeConfig {
        case currentTime
        case mockTime(Date)

        var date: Date {
            switch self {
            case .currentTime:
                return .now
            case let .mockTime(fixedDate):
                return fixedDate
            }
        }
    }

    var timeConfig: TimeConfig

    init(_ timeConfig: TimeConfig) {
        self.timeConfig = timeConfig
    }
}

extension MockTimeProvider: Equatable {
    static func == (_: MockTimeProvider, _: MockTimeProvider) -> Bool {
        true
    }
}

extension MockTimeProvider: TimeProvider {
    var presentTime: Date {
        timeConfig.date
    }

    func timeSince(_ date: Date) -> TimeInterval {
        presentTime.timeIntervalSince(date)
    }
}
