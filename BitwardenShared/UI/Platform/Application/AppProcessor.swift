import Combine
import Foundation
import UIKit

// MARK: - AppLinksError

/// The errors thrown from a `AppProcessor`.
///
enum AppProcessorError: Error {
    /// The received URL from AppLinks is malformed.
    case appLinksInvalidURL

    /// The received URL from AppLinks does not have the correct parameters.
    case appLinksInvalidParametersForPath

    /// The received URL from AppLinks does not have a valid path.
    case appLinksInvalidPath
}

/// The `AppProcessor` processes actions received at the application level and contains the logic
/// to control the top-level flow through the app.
///
@MainActor
public class AppProcessor {
    // MARK: Properties

    /// The root module to use to create sub-coordinators.
    let appModule: AppModule

    /// The root coordinator of the app.
    var coordinator: AnyCoordinator<AppRoute, AppEvent>?

    /// The services used by the app.
    let services: ServiceContainer

    // MARK: Initialization

    /// Initializes an `AppProcessor`.
    ///
    /// - Parameters:
    ///   - appModule: The root module to use to create sub-coordinators.
    ///   - services: The services used by the app.
    ///
    public init(
        appModule: AppModule,
        services: ServiceContainer
    ) {
        self.appModule = appModule
        self.services = services

        self.services.notificationService.setDelegate(self)
        self.services.syncService.delegate = self

        UI.initialLanguageCode = services.appSettingsStore.appLocale ?? Locale.current.languageCode
        UI.applyDefaultAppearances()

        Task {
            for await _ in services.notificationCenterService.willEnterForegroundPublisher() {
                let accounts = try await self.services.stateService.getAccounts()
                let activeUserId = try await self.services.stateService.getActiveAccountId()
                for account in accounts {
                    let userId = account.profile.userId
                    let shouldTimeout = try await services.vaultTimeoutService.hasPassedSessionTimeout(userId: userId)
                    if shouldTimeout {
                        await self.services.vaultTimeoutService.lockVault(userId: userId)

                        if userId == activeUserId {
                            // Allow the AuthCoordinator to handle the timeout.
                            await coordinator?.handleEvent(.didTimeout(userId: activeUserId))
                        }
                    }
                }
            }
        }

        Task {
            for await _ in services.notificationCenterService.didEnterBackgroundPublisher() {
                let userId = try await self.services.stateService.getActiveAccountId()
                try await services.vaultTimeoutService.setLastActiveTime(userId: userId)
            }
        }
    }

    // MARK: Methods

    /// Starts the application flow by navigating the user to the first flow.
    ///
    /// - Parameters:
    ///   - appContext: The context that the app is running within.
    ///   - initialRoute: The initial route to navigate to. If `nil` this, will navigate to the
    ///     unlock or landing auth route based on if there's an active account. Defaults to `nil`.
    ///   - navigator: The object that will be used to navigate between routes.
    ///   - window: The window to use to set the app's theme.
    ///
    public func start(
        appContext: AppContext,
        initialRoute: AppRoute? = nil,
        navigator: RootNavigator,
        window: UIWindow?
    ) async {
        let coordinator = appModule.makeAppCoordinator(appContext: appContext, navigator: navigator)
        coordinator.start()
        self.coordinator = coordinator

        Task {
            for await appTheme in await services.stateService.appThemePublisher().values {
                navigator.appTheme = appTheme
                window?.overrideUserInterfaceStyle = appTheme.userInterfaceStyle
            }
        }

        await services.migrationService.performMigrations()
        await services.environmentService.loadURLsForActiveAccount()
        _ = await services.configService.getConfig()

        services.application?.registerForRemoteNotifications()

        if let initialRoute {
            coordinator.navigate(to: initialRoute)
        } else {
            await coordinator.handleEvent(.didStart)
        }
    }

    /// Handle incoming URL from iOS AppLinks and redirect it to the correct navigation within the App
    ///
    /// - Parameter incomingURL: The URL handled from AppLinks.
    ///
    public func handleAppLinks(incomingURL: URL) {
        guard let components = NSURLComponents(url: incomingURL, resolvingAgainstBaseURL: true) else {
            return
        }

        // Check for specific URL components that you need.
        guard let path = components.path,
              let params = components.queryItems,
              let host = components.host else {
            services.errorReporter.log(error: AppProcessorError.appLinksInvalidURL)
            return
        }

        if path == "/finish-signup" {
            guard let email = params.first(where: { $0.name == "email" })?.value,
                  let verificationToken = params.first(where: { $0.name == "token" })?.value else {
                services.errorReporter.log(error: AppProcessorError.appLinksInvalidParametersForPath)
                return
            }

            coordinator?.navigate(to: AppRoute.auth(
                AuthRoute.completeRegistrationFromAppLink(
                    emailVerificationToken: verificationToken,
                    userEmail: email,
                    region: host.contains("bitwarden.eu") ? .europe : .unitedStates
                )))

        } else {
            services.errorReporter.log(error: AppProcessorError.appLinksInvalidPath)
        }
    }

    // MARK: Notification Methods

    /// Called when the app has registered for push notifications.
    ///
    /// - Parameter tokenData: The device token for push notifications.
    ///
    public func didRegister(withToken tokenData: Data) {
        Task {
            await services.notificationService.didRegister(withToken: tokenData)
        }
    }

    /// Called when the app failed to register for push notifications.
    ///
    /// - Parameter error: The error received.
    ///
    public func failedToRegister(_ error: Error) {
        services.errorReporter.log(error: error)
    }

    /// Called when the app has received data from a push notification.
    ///
    /// - Parameters:
    ///   - message: The content of the push notification.
    ///   - notificationDismissed: `true` if a notification banner has been dismissed.
    ///   - notificationTapped: `true` if a notification banner has been tapped.
    ///
    public func messageReceived(
        _ message: [AnyHashable: Any],
        notificationDismissed: Bool? = nil,
        notificationTapped: Bool? = nil
    ) async {
        await services.notificationService.messageReceived(
            message,
            notificationDismissed: notificationDismissed,
            notificationTapped: notificationTapped
        )
    }
}

// MARK: - NotificationServiceDelegate

extension AppProcessor: NotificationServiceDelegate {
    /// Users are logged out, route to landing page.
    ///
    func routeToLanding() async {
        coordinator?.navigate(to: .auth(.landing))
    }

    /// Show the login request.
    ///
    /// - Parameter loginRequest: The login request.
    ///
    func showLoginRequest(_ loginRequest: LoginRequest) {
        coordinator?.navigate(to: .loginRequest(loginRequest))
    }

    /// Switch the active account in order to show the login request, prompting the user if necessary.
    ///
    /// - Parameters:
    ///   - account: The account associated with the login request.
    ///   - loginRequest: The login request to show.
    ///   - showAlert: Whether to show the alert or simply switch the account.
    ///
    func switchAccounts(to account: Account, for loginRequest: LoginRequest, showAlert: Bool) {
        DispatchQueue.main.async {
            if showAlert {
                self.coordinator?.showAlert(.confirmation(
                    title: Localizations.logInRequested,
                    message: Localizations.loginAttemptFromXDoYouWantToSwitchToThisAccount(account.profile.email)
                ) {
                    self.switchAccounts(to: account.profile.userId, for: loginRequest)
                })
            } else {
                self.switchAccounts(to: account.profile.userId, for: loginRequest)
            }
        }
    }

    /// Switch to the specified account and show the login request.
    ///
    /// - Parameters:
    ///   - userId: The userId of the account to switch to.
    ///   - loginRequest: The login request to show.
    ///
    private func switchAccounts(to userId: String, for loginRequest: LoginRequest) {
        (coordinator as? VaultCoordinatorDelegate)?.didTapAccount(userId: userId)
        coordinator?.navigate(to: .loginRequest(loginRequest))
    }
}

// MARK: - SyncServiceDelegate

extension AppProcessor: SyncServiceDelegate {
    func securityStampChanged(userId: String) async {
        // Log the user out if their security stamp changes.
        coordinator?.hideLoadingOverlay()
        try? await services.authRepository.logout(userId: userId)
        await coordinator?.handleEvent(.didLogout(userId: userId, userInitiated: false))
    }

    func setMasterPassword(orgIdentifier: String) async {
        DispatchQueue.main.async { [self] in
            coordinator?.navigate(to: .auth(.setMasterPassword(organizationIdentifier: orgIdentifier)))
        }
    }
}
