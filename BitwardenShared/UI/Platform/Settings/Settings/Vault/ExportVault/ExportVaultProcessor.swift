import AuthenticationServices
import BitwardenSdk
import Foundation

// MARK: - ExportVaultProcessor

/// The processor used to manage state and handle actions for the `ExportVaultView`.
final class ExportVaultProcessor: StateProcessor<ExportVaultState, ExportVaultAction, ExportVaultEffect> {
    // MARK: Types

    typealias Services = HasAuthRepository
        & HasErrorReporter
        & HasExportVaultService
        & HasPolicyService
        & HasStateService

    // MARK: Properties

    /// The coordinator used to manage navigation.
    private let coordinator: AnyCoordinator<SettingsRoute, SettingsEvent>

    /// A delegate of the `ExportVaultProcessor` that is used to get presentation anchors.
    private weak var delegate: ExportVaultProcessorDelegate?

    /// The services used by this processor.
    private let services: Services

    // MARK: Initialization

    /// Initializes a new `ExportVaultProcessor`.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator used for navigation.
    ///   - services: The services used by the processor.
    ///
    init(
        coordinator: AnyCoordinator<SettingsRoute, SettingsEvent>,
        delegate: ExportVaultProcessorDelegate?,
        services: Services
    ) {
        self.coordinator = coordinator
        self.delegate = delegate
        self.services = services
        super.init(state: ExportVaultState())
    }

    deinit {
        // When the view is dismissed, ensure any temporary files are deleted.
        services.exportVaultService.clearTemporaryFiles()
    }

    // MARK: Methods

    override func perform(_ effect: ExportVaultEffect) async {
        switch effect {
        case .loadData:
            await loadData()
        case .sendCodeTapped:
            await sendVerificationCode()
        }
    }

    override func receive(_ action: ExportVaultAction) {
        switch action {
        case .dismiss:
            services.exportVaultService.clearTemporaryFiles()
            coordinator.navigate(to: .dismiss)
        case .exportVaultTapped:
            validateFieldsAndExportVault()
        case let .fileFormatTypeChanged(fileFormat):
            state.fileFormat = fileFormat
        case let .filePasswordTextChanged(newValue):
            state.filePasswordText = newValue
            updatePasswordStrength()
        case let .filePasswordConfirmationTextChanged(newValue):
            state.filePasswordConfirmationText = newValue
        case let .masterPasswordOrOtpTextChanged(newValue):
            state.masterPasswordOrOtpText = newValue
        case let .toastShown(newValue):
            state.toast = newValue
        case let .toggleFilePasswordVisibility(isOn):
            state.isFilePasswordVisible = isOn
        case let .toggleMasterPasswordOrOtpVisibility(isOn):
            state.isMasterPasswordOrOtpVisible = isOn
        }
    }

    // MARK: Private Methods

    /// Show an alert to confirm exporting the vault.
    private func confirmExportVault() {
        let encrypted = (state.fileFormat == .jsonEncrypted)
        let format = state.fileFormat
        let password = state.filePasswordText

        // Show the alert to confirm exporting the vault.
        coordinator.showAlert(.confirmExportVault(encrypted: encrypted) {
            // Validate the password before exporting the vault.
            guard await self.validatePassword() else {
                return
            }

            do {
                try await self.exportVault(format: format, password: password)

                // Clear the user's entered password so that it's required to be entered again for
                // any subsequent exports.
                self.state.filePasswordText = ""
                self.state.filePasswordConfirmationText = ""
                self.state.filePasswordStrengthScore = nil
                self.state.isSendCodeButtonDisabled = false
                self.state.masterPasswordOrOtpText = ""
            } catch {
                self.services.errorReporter.log(error: error)
            }
        })
    }

    /// Export a vault with a given format and trigger a share.
    ///
    /// - Parameters:
    ///    - format: The format of the export file.
    ///    - password: The password used to validate the export.
    ///
    private func exportVault(format: ExportFormatType, password: String) async throws {
        var exportFormat: ExportFileType
        switch format {
        case .csv:
            exportFormat = .csv
        case .cxp:
            if #available(iOSApplicationExtension 18.2, *) {
                try await exportVaultOnCXP()
            }
            return
        case .json:
            exportFormat = .json
        case .jsonEncrypted:
            exportFormat = .encryptedJson(password: password)
        }

        let fileURL = try await services.exportVaultService.exportVault(format: exportFormat)
        coordinator.navigate(to: .shareExportedVault(fileURL))
    }

    /// Exports the vault using Credential Exchange protocol
    @available(iOSApplicationExtension 18.2, *)
    private func exportVaultOnCXP() async throws {
        guard let delegate else {
            return
        }

        coordinator.showLoadingOverlay(title: Localizations.loading)
        defer { coordinator.hideLoadingOverlay() }

        let data = try await services.exportVaultService.exportVaultForCXP()
        let exportManager = ASCredentialExportManager(
            presentationAnchor: delegate.presentationAnchorForASCredentialExportManager()
        )
        coordinator.hideLoadingOverlay()
        do {
            let exportedData = ASExportedCredentialData(accounts: [data])
            try await exportManager.exportCredentials(exportedData)
        } catch ASAuthorizationError.failed {
            coordinator
                .showAlert(
                    .defaultAlert(
                        title: Localizations.exportingFailed,
                        message: Localizations.youMayNeedToEnableDevicePasscodeOrBiometrics
                    )
                )
        }
    }

    /// Load any initial data for the view.
    ///
    private func loadData() async {
        state.disableIndividualVaultExport = await services.policyService.policyAppliesToUser(
            .disablePersonalVaultExport
        )

        do {
            state.hasMasterPassword = try await services.stateService.getUserHasMasterPassword()
        } catch {
            coordinator.showAlert(.defaultAlert(title: Localizations.anErrorHasOccurred))
            services.errorReporter.log(error: error)
        }
    }

    /// Sends a one-time password code to the user for verification.
    ///
    private func sendVerificationCode() async {
        coordinator.showLoadingOverlay(LoadingOverlayState(title: Localizations.sendingCode))
        defer { coordinator.hideLoadingOverlay() }

        do {
            try await services.authRepository.requestOtp()
            state.isSendCodeButtonDisabled = true
            state.toast = Toast(title: Localizations.codeSent)
        } catch {
            coordinator.showAlert(.networkResponseError(error))
            services.errorReporter.log(error: error)
        }
    }

    /// Updates state's password strength score based on the user's entered password.
    ///
    private func updatePasswordStrength() {
        guard !state.filePasswordText.isEmpty else {
            state.filePasswordStrengthScore = nil
            return
        }
        Task {
            state.filePasswordStrengthScore = try? await services.authRepository.passwordStrength(
                email: "",
                password: state.filePasswordText,
                isPreAuth: false
            )
        }
    }

    /// Validates the input fields and if they are valid, shows the alert to confirm the vault export.
    ///
    private func validateFieldsAndExportVault() {
        let isEncryptedExport = state.fileFormat == .jsonEncrypted

        do {
            if isEncryptedExport {
                try EmptyInputValidator(fieldName: Localizations.filePassword)
                    .validate(input: state.filePasswordText)
                try EmptyInputValidator(fieldName: Localizations.confirmFilePassword)
                    .validate(input: state.filePasswordConfirmationText)

                guard state.filePasswordText == state.filePasswordConfirmationText else {
                    coordinator.showAlert(.passwordsDontMatch)
                    return
                }
            }

            try EmptyInputValidator(fieldName: state.masterPasswordOrOtpTitle)
                .validate(input: state.masterPasswordOrOtpText)

            confirmExportVault()
        } catch let error as InputValidationError {
            coordinator.showAlert(.inputValidationAlert(error: error))
        } catch {
            coordinator.showAlert(.networkResponseError(error))
            services.errorReporter.log(error: error)
        }
    }

    /// Validate the password or OTP code.
    ///
    /// - Returns: `true` if the password or OTP code is valid.
    ///
    private func validatePassword() async -> Bool {
        do {
            if state.hasMasterPassword {
                let isValid = try await services.authRepository.validatePassword(state.masterPasswordOrOtpText)
                guard isValid else {
                    coordinator.showAlert(.defaultAlert(title: Localizations.invalidMasterPassword))
                    return false
                }
                return true
            } else {
                try await services.authRepository.verifyOtp(state.masterPasswordOrOtpText)
                return true
            }
        } catch ServerError.error {
            coordinator.showAlert(.defaultAlert(title: Localizations.invalidVerificationCode))
            return false
        } catch {
            coordinator.showAlert(.networkResponseError(error))
            services.errorReporter.log(error: error)
            return false
        }
    }
}

/// A protocol delegate for the `ExportVaultProcessor`.
protocol ExportVaultProcessorDelegate: AnyObject {
    /// Returns an `ASPresentationAnchor` to be used when creating an `ASCredentialExportManager`.
    /// - Returns: An `ASPresentationAnchor`.
    func presentationAnchorForASCredentialExportManager() -> ASPresentationAnchor
}
