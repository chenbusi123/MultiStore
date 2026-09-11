//
//  AccountManager+Actions.swift
//  AltStore
//
//  App-layer account actions that require the signing/refresh pipeline (AppManager,
//  AuthenticationOperation). The data/credential facade lives in
//  AltStoreCore/Managers/AccountManager.swift; this extension adds the interactive operations.
//

import Foundation
import CoreData
import UIKit

import AltStoreCore
import AltSign

extension AccountManager
{
    /// Add a new Apple account by presenting the sign-in UI, forcing a fresh login so a *new*
    /// Apple ID can be entered rather than silently re-authenticating the current account. The
    /// existing default account is preserved; the user can explicitly make the new account the
    /// default afterwards. Returns the resolved `Account` (a view-context object) on success.
    @discardableResult
    func addAccount(presentingViewController: UIViewController, completionHandler: @escaping (Result<Account, Error>) -> Void) -> AuthenticationOperation
    {
        let context = AuthenticatedOperationContext()
        context.ignoresCachedCredentials = true
        context.updatesDefaultAccount = false

        return AppManager.shared.authenticate(presentingViewController: presentingViewController, context: context, skipDeviceRegistration: false) { result in
            switch result
            {
            case .failure(let error):
                completionHandler(.failure(error))

            case .success(let (team, _, _)):
                let accountID = team.account.identifier
                DispatchQueue.main.async {
                    if let account = self.account(accountID, in: DatabaseManager.shared.viewContext)
                    {
                        completionHandler(.success(account))
                    }
                    else
                    {
                        completionHandler(.failure(OperationError.unknown()))
                    }
                }
            }
        }
    }

    /// Refresh every installed app signed by the given account, authenticating as that account.
    @discardableResult
    func refreshAccount(_ accountID: String, presentingViewController: UIViewController?, completionHandler: @escaping (Result<[String: Result<InstalledApp, Error>], Error>) -> Void = { _ in }) -> RefreshGroup
    {
        let apps = self.appsForAccount(accountID, in: DatabaseManager.shared.viewContext)

        let group = RefreshGroup()
        group.context.accountID = accountID
        group.completionHandler = { results in
            completionHandler(.success(results))
        }

        // Nothing to refresh — complete through the group so any group-based observers finish too.
        guard !apps.isEmpty else {
            group.completionHandler?([:])
            return group
        }

        return AppManager.shared.refresh(apps, presentingViewController: presentingViewController, group: group)
    }

    /// Remove an account and its stored credentials on a background context.
    func removeAccount(_ accountID: String, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            do
            {
                try self.deleteAccount(accountID, in: context)
                DispatchQueue.main.async { completionHandler(.success(())) }
            }
            catch
            {
                DispatchQueue.main.async { completionHandler(.failure(error)) }
            }
        }
    }

    /// Reassign an installed app to a different signing account and re-sign it with that account.
    func changeSigningAccount(for installedApp: InstalledApp, to accountID: String, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        let bundleIdentifier = installedApp.bundleIdentifier
        var previousAccountID: String?
        var previousTeamID: String?
        var previousNeedsResign = false
        installedApp.managedObjectContext?.performAndWait {
            previousAccountID = installedApp.signingAccountID
            previousTeamID = installedApp.team?.identifier
            previousNeedsResign = installedApp.needsResign
        }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.performAndWait {
            guard self.assignAccount(accountID, toAppWithBundleIdentifier: bundleIdentifier, in: context) else {
                DispatchQueue.main.async { completionHandler(.failure(OperationError.appNotFound(name: installedApp.name))) }
                return
            }

            do { try context.save() }
            catch {
                DispatchQueue.main.async { completionHandler(.failure(error)) }
                return
            }

            DispatchQueue.main.async {
                // Re-sign with the newly-assigned account (inferred from the app's signingAccountID).
                let app = DatabaseManager.shared.viewContext.object(with: installedApp.objectID) as? InstalledApp ?? installedApp
                _ = AppManager.shared.resign(app, presentingViewController: presentingViewController) { result in
                    switch result
                    {
                    case .success:
                        completionHandler(result)

                    case .failure(let error):
                        // Reassignment is only real after the replacement signature installs.
                        // Restore the old mapping if authentication, signing, or installation
                        // fails so future refreshes do not use an account that never signed it.
                        self.restoreSigningAssignment(
                            forBundleIdentifier: bundleIdentifier,
                            accountID: previousAccountID,
                            teamID: previousTeamID,
                            needsResign: previousNeedsResign
                        ) { restoreResult in
                            switch restoreResult
                            {
                            case .success: completionHandler(.failure(error))
                            case .failure(let restoreError): completionHandler(.failure(restoreError))
                            }
                        }
                    }
                }
            }
        }
    }

    private func restoreSigningAssignment(forBundleIdentifier bundleIdentifier: String,
                                          accountID: String?,
                                          teamID: String?,
                                          needsResign: Bool,
                                          completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            do
            {
                let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), bundleIdentifier)
                guard let app = InstalledApp.first(satisfying: predicate, in: context) else {
                    throw OperationError.appNotFound(name: bundleIdentifier)
                }

                app.signingAccountID = accountID
                if let teamID = teamID
                {
                    app.team = Team.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Team.identifier), teamID), in: context)
                }
                else
                {
                    app.team = nil
                }
                app.needsResign = needsResign
                try context.save()
                DispatchQueue.main.async { completionHandler(.success(())) }
            }
            catch
            {
                DispatchQueue.main.async { completionHandler(.failure(error)) }
            }
        }
    }
}
