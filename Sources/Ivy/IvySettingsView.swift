import SwiftUI
import IvyCore
import LeafiyUICore
import LeafiyUI

struct IvySettingsView: View {
    @ObservedObject var model: IvyModel

    var body: some View {
        LeafiyFamilySettings(language: model.settings.selectedAppLanguage) {
            LeafiyGeneralPane(
                language: appLanguageBinding,
                launchAtLogin: settingsBinding(\.launchAtLogin),
                applicationIconMode: settingsBinding(\.applicationIconMode),
                tail: {
                    Picker(L("Default Note Color"), selection: settingsBinding(\.defaultNoteColor)) {
                        ForEach(NoteColor.allCases, id: \.rawValue) { color in
                            Text(L(color.localizationKey)).tag(color.rawValue)
                        }
                    }
                }
            )
            LeafiyUI.SettingsPane(
                L("Sync"),
                systemImage: "arrow.triangle.2.circlepath",
                height: LeafiyDesign.Size.settingsPaneHeight
            ) {
                AccountSettingsContent(
                    controller: model.accountController,
                    namespace: settingsBinding(\.namespace)
                )
            }
        }
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settings.selectedAppLanguage },
            set: { language in
                model.updateSettings { $0.selectedAppLanguage = language }
            }
        )
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                model.updateSettings { $0[keyPath: keyPath] = value }
            }
        )
    }
}

private struct AccountSettingsContent: View {
    private enum EmailAction: String, CaseIterable {
        case register
        case signIn
    }

    @ObservedObject var controller: AccountSyncController
    @Binding var namespace: String
    @State private var emailAction = EmailAction.signIn
    @State private var email = ""
    @State private var verificationCode = ""
    @State private var password = ""

    private var hasNamespace: Bool {
        !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if let account = controller.account {
            signedInContent(account)
        } else {
            signedOutContent
        }
    }

    @ViewBuilder
    private func signedInContent(_ account: AuthUser) -> some View {
        Section(account.accountType == "namespace" ? L("Public Space") : L("Private Account")) {
            if let namespace = account.namespace {
                LabeledContent(L("Namespace"), value: namespace)
            } else {
                LabeledContent(L("Sign-In Method"), value: privateSignInMethods(account.methods))
                if let email = account.email {
                    LabeledContent(L("Email Address"), value: email)
                        .textSelection(.enabled)
                }
            }
            LabeledContent(L("Sync Status"), value: controller.syncStatus)
            HStack {
                Button(L("Sync Now")) { controller.syncNow() }
                    .disabled(controller.isWorking)
                Spacer()
                Button(L("Sign Out"), role: .destructive) { controller.signOut() }
            }
        }

        Section(L("Storage")) {
            CapacityRow(
                title: L("Notes Database"),
                usedMB: controller.noteDatabaseUsageMB,
                limitMB: controller.noteDatabaseLimitMB,
                icon: .notesDatabase
            )
            CapacityRow(
                title: L("Attachments"),
                usedMB: controller.attachmentUsageMB,
                limitMB: controller.attachmentLimitMB,
                icon: .paperclip
            )
            Text(L("Notes stop syncing above 10 MB. Attachments stop uploading above 50 MB."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        statusMessage
    }

    private var signedOutContent: some View {
        Group {
            Section(L("Public Space")) {
                TextField(L("Namespace"), text: $namespace)
                    .onSubmit {
                        guard hasNamespace, !controller.isWorking else { return }
                        controller.join(namespace: namespace)
                    }
                Text(L("Public and password-free. Anyone with this namespace can enter and share it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(L("Join Space")) {
                        controller.join(namespace: namespace)
                    }
                    Button(L("Create Space")) {
                        controller.create(namespace: namespace)
                    }
                }
                .disabled(controller.isWorking || !controller.providers.passwordless.enabled || !hasNamespace)
            }

            Section(L("Private Account")) {
                Text(L("Private accounts are completely separate from public namespaces."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    controller.signInWithGoogle()
                } label: {
                    Text(L("Continue with Google"))
                }
                .disabled(controller.isWorking || !controller.providers.google.enabled)

                if !controller.providers.google.enabled {
                    Text(L("Some private sign-in options are currently unavailable."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if controller.providers.email.enabled {
                Section(L("Email")) {
                    emailForm
                }
            }

            statusMessage
        }
        .task {
            await controller.loadProviderConfiguration()
        }
    }

    private var emailForm: some View {
        Group {
            Picker(L("Email Action"), selection: $emailAction) {
                Text(L("Register")).tag(EmailAction.register)
                Text(L("Sign In")).tag(EmailAction.signIn)
            }
            .pickerStyle(.segmented)
            TextField(L("Email"), text: $email)
                .textContentType(.emailAddress)
            SecureField(L("Password"), text: $password)
                .textContentType(emailAction == .register ? .newPassword : .password)

            if emailAction == .register {
                HStack {
                    TextField(L("Verification Code"), text: $verificationCode)
                    Button(L("Send Code")) { controller.sendEmailCode(email: email) }
                        .disabled(controller.isWorking || email.isEmpty)
                }
                Button(L("Register with Email")) {
                    controller.registerWithEmail(
                        email: email,
                        code: verificationCode,
                        password: password
                    )
                }
                .disabled(
                    controller.isWorking
                    || email.isEmpty
                    || verificationCode.isEmpty
                    || password.isEmpty
                    || !controller.providers.email.enabled
                )
            } else {
                Button(L("Sign In with Email")) {
                    controller.signInWithEmail(email: email, password: password)
                }
                .disabled(
                    controller.isWorking
                    || email.isEmpty
                    || password.isEmpty
                    || !controller.providers.email.enabled
                )
            }
        }
    }

    private func privateSignInMethods(_ methods: [String]) -> String {
        let names = methods.compactMap { method -> String? in
            switch method {
            case "google": L("Google")
            case "password": L("Email")
            default: nil
            }
        }
        return names.isEmpty ? L("Private Account") : names.joined(separator: ", ")
    }

    @ViewBuilder
    private var statusMessage: some View {
        if controller.isWorking {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Working"))
                        .foregroundStyle(.secondary)
                }
            }
        } else if let message = controller.message {
            Section {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}


private struct CapacityRow: View {
    let title: String
    let usedMB: Double
    let limitMB: Double
    let icon: IvyIcon

    private var isOverLimit: Bool { usedMB > limitMB }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                IvyIconLabel(title, icon: icon)
                Spacer()
                Text(String(format: "%.2f MB / %.0f MB", usedMB, limitMB))
                    .monospacedDigit()
                    .foregroundStyle(isOverLimit ? .red : .secondary)
            }
            ProgressView(value: min(usedMB, limitMB), total: max(limitMB, 0.01))
                .tint(isOverLimit ? .red : .accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}

