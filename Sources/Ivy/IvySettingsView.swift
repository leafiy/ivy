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
            IvySettingsPane(L("Sync"), icon: .sync, height: 610) {
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
                        controller.enter(namespace: namespace)
                    }
                Text(L("Public and password-free. Anyone with this namespace can enter and share it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    controller.enter(namespace: namespace)
                } label: {
                    IvyIconLabel(L("Continue with Ivy"), icon: .leaf, iconSize: 16)
                }
                .buttonStyle(ProviderSignInButtonStyle())
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
                .buttonStyle(ProviderSignInButtonStyle())
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

private struct ProviderSignInButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.black.opacity(0.82), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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

/// A family-sized settings tab whose icon comes from Ivy's unified Lucide set.
private struct IvySettingsPane<Content: View>: View {
    let title: String
    let icon: IvyIcon
    let height: CGFloat
    let content: Content

    init(
        _ title: String,
        icon: IvyIcon,
        height: CGFloat = LeafiyDesign.Size.settingsPaneHeight,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.height = height
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(width: LeafiyDesign.Size.settingsPaneWidth, height: height)
        .tabItem {
            IvyIconLabel(title, icon: icon, iconSize: 16)
        }
    }
}
