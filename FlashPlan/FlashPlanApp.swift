//
//  FlashPlanApp.swift
//  FlashPlan
//
//  Created by Bradly Belcher on 2/4/26.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import Combine
import Observation
import FirebaseDatabase

// MARK: - App Links

enum AppLinks {
    // Reads a custom Info.plist key `AssociatedBaseURL` if present, otherwise falls back to a sensible default.
    // Example value: applinks:flashplan-e6166.web.app
    static var baseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "AssociatedBaseURL") as? String {
            // Normalize applinks: scheme to https:// for sharing and universal links
            let normalized: String = {
                if raw.lowercased().hasPrefix("applinks:") {
                    let host = raw.dropFirst("applinks:".count)
                    return "https://" + host
                }
                return raw
            }()
            if let url = URL(string: normalized), let scheme = url.scheme, scheme.hasPrefix("http") {
                return url
            }
        }
        // Fallback to the universal link domain you configured in Associated Domains.
        // Updated to use your actual Firebase Hosting domain.
        return URL(string: "https://flashplan-e6166.web.app")!
    }
    
    static func planURL(id: String) -> URL { baseURL.appendingPathComponent("p").appendingPathComponent(id) }
    static func groupURL(id: String) -> URL { baseURL.appendingPathComponent("g").appendingPathComponent(id) }
}

// MARK: - Theme Manager

@Observable
final class AppThemeManager {
    var globalTheme: Theme = ThemeCatalog.defaultTheme

    func themeForGroup(key: String?) -> Theme {
        guard let key, !key.isEmpty else { return globalTheme }
        return ThemeCatalog.all.first(where: { $0.key == key }) ?? globalTheme
    }
}

// MARK: - App Entry

@main
struct FlashPlanApp: App {
    @StateObject private var session: SessionStore
    @State private var router = DeepLinkRouter()
    @State private var themeManager = AppThemeManager()

    init() {
        // Configure Firebase before any Firebase APIs are used.
        FirebaseApp.configure()
        if let app = FirebaseApp.app() {
            let opts = app.options
            print("[Firebase] Configured. projectID=\(opts.projectID ?? "nil"), appID=\(opts.googleAppID), gcmSenderID=\(opts.gcmSenderID)")
        } else {
            print("[Firebase] Configuration FAILED: FirebaseApp.app() is nil")
        }
        // Initialize SessionStore after Firebase is configured.
        _session = StateObject(wrappedValue: SessionStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environment(router)
                .environment(themeManager)
                // Custom scheme support (optional): flashplan://p/<id>
                .onOpenURL { url in router.handle(url: url) }
                // Universal Links support: https://flashplan.example/p/<id>
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { router.handle(url: url) }
                }
        }
    }
}

// MARK: - Deep Link Router

@MainActor
@Observable
final class DeepLinkRouter {
    var pendingPlanId: String? = nil
    var pendingGroupId: String? = nil

    // Accepts:
    // - https://flashplan.example/p/<planId>
    // - https://flashplan.example/g/<groupId>
    // - flashplan://p/<planId>
    // - flashplan://g/<groupId>
    func handle(url: URL) {
        // Universal link: /p/<id> or /g/<id>
        let comps = url.pathComponents // ["", "p"|"g", "<id>"]
        if comps.count >= 3, comps[1].lowercased() == "p" {
            pendingPlanId = comps[2]
            return
        }
        if comps.count >= 3, comps[1].lowercased() == "g" {
            pendingGroupId = comps[2]
            return
        }

        // Custom scheme: flashplan://p/<id> or flashplan://g/<id>
        if url.scheme?.lowercased() == "flashplan",
           url.host?.lowercased() == "p",
           url.pathComponents.count >= 2 {
            pendingPlanId = url.pathComponents[1]
            return
        }
        if url.scheme?.lowercased() == "flashplan",
           url.host?.lowercased() == "g",
           url.pathComponents.count >= 2 {
            pendingGroupId = url.pathComponents[1]
            return
        }
    }

    func consumePendingPlanId() -> String? {
        defer { pendingPlanId = nil }
        return pendingPlanId
    }

    func consumePendingGroupId() -> String? {
        defer { pendingGroupId = nil }
        return pendingGroupId
    }
}

// MARK: - Models

enum Vote: String, CaseIterable, Identifiable {
    case yes, maybe, no
    var id: String { rawValue }

    var label: String {
        switch self {
        case .yes: return "Yes"
        case .maybe: return "Maybe"
        case .no: return "No"
        }
    }

    var symbol: String {
        switch self {
        case .yes: return "checkmark.circle.fill"
        case .maybe: return "questionmark.circle.fill"
        case .no: return "xmark.circle.fill"
        }
    }
}

struct Plan: Identifiable {
    let id: String
    var title: String
    var when: Date
    var location: String
    var notes: String
    var createdBy: String
    var createdAt: Date

    init(id: String, data: [String: Any]) {
        self.id = id
        self.title = data["title"] as? String ?? ""
        self.location = data["location"] as? String ?? ""
        self.notes = data["notes"] as? String ?? ""
        self.createdBy = data["createdBy"] as? String ?? ""
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.when = (data["when"] as? Timestamp)?.dateValue() ?? Date()
    }

    var toFirestore: [String: Any] {
        [
            "title": title,
            "when": Timestamp(date: when),
            "location": location,
            "notes": notes,
            "createdBy": createdBy,
            "createdAt": Timestamp(date: createdAt)
        ]
    }
}

struct PlanVote: Identifiable {
    let id: String // uid
    let name: String
    let vote: Vote
    let updatedAt: Date

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = data["name"] as? String ?? "Someone"
        self.vote = Vote(rawValue: (data["vote"] as? String ?? "maybe")) ?? .maybe
        self.updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
    }
}

// MARK: - Session (Firebase Auth)

@MainActor
final class SessionStore: ObservableObject {
    @Published var user: FirebaseAuth.User?
    @Published var displayName: String = "You"
    @Published var authError: String?

    private let usersService = UsersService()

    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        handle = Auth.auth().addStateDidChangeListener { _, user in
            Task { @MainActor in
                print("[Auth] State changed. user=\(user?.uid ?? "nil") email=\(user?.email ?? "nil")")
                self.user = user
                self.authError = nil
                if let email = user?.email, !email.isEmpty {
                    self.displayName = email.split(separator: "@").first.map(String.init) ?? "You"
                } else {
                    self.displayName = "You"
                }
                if let user {
                    do {
                        try await self.usersService.ensureUserDocument(uid: user.uid, displayName: self.displayName, email: user.email)
                        print("[Users] ensureUserDocument success for uid=\(user.uid)")
                    } catch {
                        print("[Users] ensureUserDocument error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func signIn(email: String, password: String) async {
        do {
            let res = try await Auth.auth().signIn(withEmail: email, password: password)
            self.user = res.user
            print("[Auth] Sign in success uid=\(res.user.uid)")
        } catch {
            self.authError = error.localizedDescription
            print("[Auth] Sign in failed: \(error.localizedDescription)")
        }
    }

    func signUp(email: String, password: String, displayName: String) async {
        do {
            let res = try await Auth.auth().createUser(withEmail: email, password: password)
            let user = res.user
            // Update Firebase Auth profile display name
            do {
                let changeRequest = user.createProfileChangeRequest()
                changeRequest.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                try await changeRequest.commitChanges()
            } catch {
                print("[Auth] Failed to update displayName: \(error.localizedDescription)")
            }
            self.user = user
            // Prefer the provided displayName, fallback to email prefix
            let provided = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !provided.isEmpty {
                self.displayName = provided
            } else if let email = user.email, !email.isEmpty {
                self.displayName = email.split(separator: "@").first.map(String.init) ?? "You"
            }
            print("[Auth] Sign up success uid=\(user.uid)")
            do {
                try await usersService.ensureUserDocument(uid: user.uid, displayName: self.displayName, email: user.email)
                print("[Users] ensureUserDocument success for uid=\(user.uid)")
            } catch {
                print("[Users] ensureUserDocument error: \(error.localizedDescription)")
            }
        } catch {
            self.authError = error.localizedDescription
            print("[Auth] Sign up failed: \(error.localizedDescription)")
        }
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            self.user = nil
            print("[Auth] Signed out")
        } catch {
            self.authError = error.localizedDescription
            print("[Auth] Sign out failed: \(error.localizedDescription)")
        }
    }
    
    func updateContactInfo(displayName: String?, email: String?) async {
        guard let user = Auth.auth().currentUser else { return }
        do {
            // Update display name if provided
            if let dn = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !dn.isEmpty {
                let change = user.createProfileChangeRequest()
                change.displayName = dn
                try await change.commitChanges()
                await MainActor.run { self.displayName = dn }
            }
            // Update email if provided
            if let e = email?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty, e != user.email {
                try await user.updateEmail(to: e)
            }
            try await usersService.ensureUserDocument(uid: user.uid, displayName: displayName, email: email)
        } catch {
            await MainActor.run { self.authError = error.localizedDescription }
            print("[Account] Update contact info failed: \(error.localizedDescription)")
        }
    }

    func deleteAccountPermanently() async {
        guard let user = Auth.auth().currentUser else { return }
        do {
            // Best-effort: delete user profile document
            do { try await usersService.userRef(user.uid).delete() } catch { }
            // Delete Auth user
            try await user.delete()
            await MainActor.run { self.user = nil }
            print("[Account] Account deleted")
        } catch {
            await MainActor.run { self.authError = error.localizedDescription }
            print("[Account] Delete failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Firestore Service

final class PlansService {
    private let db = Firestore.firestore()

    func plansQuery() -> Query {
        db.collection("plans")
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
    }

    func planRef(_ planId: String) -> DocumentReference {
        db.collection("plans").document(planId)
    }

    func votesRef(_ planId: String) -> CollectionReference {
        db.collection("plans").document(planId).collection("votes")
    }

    func updatePlan(_ planId: String, fields: [String: Any]) async throws {
        try await planRef(planId).updateData(fields)
    }

    func deletePlan(_ planId: String) async throws {
        try await planRef(planId).delete()
    }
}

// MARK: - Users Service

final class UsersService {
    private let db = Firestore.firestore()

    func userRef(_ uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }

    func userGroupsRef(_ uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("groups")
    }
    func userPlansRef(_ uid: String) -> CollectionReference {
            db.collection("users").document(uid).collection("plans")
        }

        func userPlanVotesRef(_ uid: String) -> CollectionReference {
            db.collection("users").document(uid).collection("planVotes")
        }

        func userAvailabilityRef(_ uid: String) -> CollectionReference {
            db.collection("users").document(uid).collection("availability")
        }
    /// Creates or updates a minimal user profile document so users can be linked to multiple groups.
    func ensureUserDocument(uid: String, displayName: String?, email: String?) async throws {
        let data: [String: Any] = {
            var d: [String: Any] = [
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let displayName, !displayName.isEmpty { d["displayName"] = displayName }
            if let email, !email.isEmpty { d["email"] = email }
            // Set createdAt too; if the document exists this will update it, which is acceptable for our needs.
            d["createdAt"] = FieldValue.serverTimestamp()
            return d
        }()
        try await userRef(uid).setData(data, merge: true)
    }

    func linkGroup(uid: String, groupId: String, role: String, groupName: String?) async throws {
        var data: [String: Any] = [
            "role": role,
            "linkedAt": Timestamp(date: Date())
        ]
        if let groupName, !groupName.isEmpty {
            data["groupName"] = groupName
        }
        try await userGroupsRef(uid).document(groupId).setData(data, merge: true)
    }

    func unlinkGroup(uid: String, groupId: String) async throws {
        try await userGroupsRef(uid).document(groupId).delete()
    }
    
    func linkPlan(uid: String, planId: String, title: String, when: Date) async throws {
        try await userPlansRef(uid).document(planId).setData([
            "title": title,
            "when": Timestamp(date: when),
            "linkedAt": Timestamp(date: Date())
        ], merge: true)
    }

    func recordPlanVote(uid: String, planId: String, vote: Vote) async throws {
        try await userPlanVotesRef(uid).document(planId).setData([
            "vote": vote.rawValue,
            "updatedAt": Timestamp(date: Date())
        ], merge: true)
    }

    func recordAvailability(uid: String, groupId: String, freeDates: Set<String>) async throws {
        try await userAvailabilityRef(uid).document(groupId).setData([
            "freeDates": Array(freeDates),
            "updatedAt": Timestamp(date: Date())
        ], merge: true)
    }
}

// MARK: - ViewModels

@MainActor
final class PlansVM: ObservableObject {
    @Published var plans: [Plan] = []
    @Published var error: String?

    private let service = PlansService()
    private let users = UsersService()
    private var listener: ListenerRegistration?

    func start() {
        listener?.remove()
        listener = service.plansQuery().addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err {
                self.error = err.localizedDescription
                print("[Plans] Listener error: \(err.localizedDescription)")
                return
            }
            let docs = snap?.documents ?? []
            self.plans = docs.map { Plan(id: $0.documentID, data: $0.data()) }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    func createPlan(title: String, when: Date, location: String, notes: String, uid: String) async throws -> String {
        let id = UUID().uuidString
        let plan = Plan(
            id: id,
            data: [
                "title": title,
                "when": Timestamp(date: when),
                "location": location,
                "notes": notes,
                "createdBy": uid,
                "createdAt": Timestamp(date: Date())
            ]
        )
        try await service.planRef(id).setData(plan.toFirestore)
        try await users.linkPlan(uid: uid, planId: id, title: title, when: when)
        return id
    }
}

@MainActor
final class PlanDetailVM: ObservableObject {
    @Published var plan: Plan?
    @Published var votes: [PlanVote] = []
    @Published var error: String?

    private let service = PlansService()
    private let users = UsersService()
    
    private var planListener: ListenerRegistration?
    private var votesListener: ListenerRegistration?

    func start(planId: String) {
        stop()

        planListener = service.planRef(planId).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err { self.error = err.localizedDescription; return }
            guard let data = snap?.data() else { return }
            self.plan = Plan(id: planId, data: data)
        }

        votesListener = service.votesRef(planId).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err { self.error = err.localizedDescription; return }
            let docs = snap?.documents ?? []
            self.votes = docs.map { PlanVote(id: $0.documentID, data: $0.data()) }
        }
    }

    func stop() {
        planListener?.remove()
        votesListener?.remove()
        planListener = nil
        votesListener = nil
    }

    func setVote(planId: String, uid: String, name: String, vote: Vote) async throws {
        let data: [String: Any] = [
            "name": name,
            "vote": vote.rawValue,
            "updatedAt": Timestamp(date: Date())
        ]
        try await service.votesRef(planId).document(uid).setData(data, merge: true)
        try await users.recordPlanVote(uid: uid, planId: planId, vote: vote)
    }

    func counts() -> (yes: Int, maybe: Int, no: Int) {
        (
            votes.filter { $0.vote == .yes }.count,
            votes.filter { $0.vote == .maybe }.count,
            votes.filter { $0.vote == .no }.count
        )
    }

    func myVote(uid: String) -> Vote? {
        votes.first(where: { $0.id == uid })?.vote
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// Inserted CreatePlanView here:

struct CreatePlanView: View {
    var onCreate: (String, Date, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppThemeManager.self) private var theme

    @State private var title = ""
    @State private var when = Date()
    @State private var location = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("What’s the plan?", text: $title)
                }
                Section("When") {
                    DatePicker("Date & Time", selection: $when, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Details") {
                    TextField("Location", text: $location)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .tint(theme.globalTheme.accent)
            .navigationTitle("New Plan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        onCreate(
                            t,
                            when,
                            location.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .themedToolbarBackground(theme.globalTheme)
        }
    }
}

// Modified CreateGroupView per instructions

struct CreateGroupView: View {
    var onCreate: (String, @escaping () -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppThemeManager.self) private var theme
    @State private var name = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .tint(theme.globalTheme.accent)
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isWorking ? "Creating…" : "Create") {
                        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty else { return }
                        isWorking = true
                        onCreate(n) {
                            // completion called after the parent finishes creating & navigating
                            isWorking = false
                            dismiss()
                        }
                    }
                    .disabled(isWorking)
                }
            }
            .themedToolbarBackground(theme.globalTheme)
        }
    }
}

struct GroupDetailView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme
    let groupId: String

    @StateObject private var vm = GroupDetailVM()
    @State private var showShare = false
    @State private var showTheme = false
    @State private var showInvite = false

    // Added showAvailability state for new availability sheet
    @State private var showAvailability = false

    private var inviteURL: URL { AppLinks.groupURL(id: groupId) }

    private var currentTheme: AppTheme { theme.themeForGroup(key: vm.group?.themeKey) }

    var body: some View {
        VStack(spacing: 12) {
            if let group = vm.group {
                groupHeaderCard(theme: currentTheme)
                GroupFreeCalendarView(membersCount: vm.members.count, availability: vm.availability)
                    .padding(.horizontal)
                nonMemberActions(theme: currentTheme)
                membersList
            } else {
                ProgressView("Loading…").padding()
            }
        }
        .padding(.vertical, 8)
        .background(currentTheme.gradient.opacity(0.06))
        .navigationTitle("Group")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTheme = true
                } label: {
                    Image(systemName: "paintbrush")
                }
            }
            // Added toolbar button for availability view
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAvailability = true
                } label: {
                    Image(systemName: "calendar")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let me = session.user?.uid, vm.isAdmin(uid: me) {
                    Button {
                        showInvite = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                if let me = session.user?.uid, vm.isAdmin(uid: me), let group = vm.group, !group.joinRequests.isEmpty {
                    NavigationLink(value: "requests") {
                        Label("Requests", systemImage: "person.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showShare) {
            // Compose a friendly share message with link and invite code
            let codeText: String = vm.group?.inviteCode ?? ""
            let message: String = {
                var parts: [String] = []
                parts.append("Join our group on FlashPlan!")
                if !codeText.isEmpty { parts.append("Invite Code: \(codeText)") }
                parts.append("Link: \(inviteURL.absoluteString)")
                parts.append("Download FlashPlan to join: https://flashplan-e6166.web.app")
                return parts.joined(separator: "\n")
            }()
            // Share both the message text and the URL for rich previews
            ShareSheet(items: [message, inviteURL])
        }
        .sheet(isPresented: $showTheme) {
            if let group = vm.group {
                GroupThemePicker(
                    group: group,
                    vm: vm,
                    currentKey: group.themeKey
                ) {
                    showTheme = false
                }
            } else {
                EmptyView()
            }
        }
        .sheet(isPresented: $showInvite) {
            InviteCodeView(vm: vm) { showInvite = false }
        }
        // Added sheet for availability view
        .sheet(isPresented: $showAvailability) {
            GroupAvailabilityView(groupId: groupId)
                .environmentObject(session)
                .environment(theme)
        }
        .tint(currentTheme.accent)
        .themedToolbarBackground(currentTheme)
        .onAppear { vm.start(groupId: groupId) }
        .onDisappear { vm.stop() }
        .navigationDestination(for: String.self) { route in
            if route == "requests" {
                RequestsView(groupId: groupId)
                    .environmentObject(session)
                    .environment(theme)
            }
        }
    }

    private func groupHeaderCard(theme currentTheme: AppTheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(currentTheme.gradient)
                .opacity(0.35)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(currentTheme.gradient)
                        .frame(width: 36, height: 36)
                        .overlay(Image(systemName: "person.3.fill").foregroundStyle(.white.opacity(0.9)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.group?.name ?? "").font(.title3).bold()
                        Text("Members: \(vm.members.count)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let code = vm.group?.inviteCode {
                        Text("Code: \(code)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .tint(currentTheme.accent)
                }
            }
            .padding(16)
        }
        .socialCardStyle(theme: currentTheme)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func nonMemberActions(theme currentTheme: AppTheme) -> some View {
        if let uid = session.user?.uid, !vm.isMember(uid: uid) {
            Button {
                guard let uid = session.user?.uid else { return }
                Task {
                    do {
                        try await vm.service.requestToJoin(groupId: groupId, uid: uid, name: session.displayName)
                        print("[Group] Request to join submitted")
                    } catch {
                        print("[Group] Request to join failed: \(error.localizedDescription)")
                    }
                }
            } label: {
                Text("Request to Join")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .tint(currentTheme.accent)

            Button("Have a code? Enter it") {
                showInvite = true
            }
            .font(.footnote)
            .padding(.horizontal)
        } else {
            EmptyView()
        }
    }

    private var membersList: some View {
        List {
            Section("Members") {
                if vm.members.isEmpty {
                    Text("No members yet. Share the invite link.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.members) { m in
                        memberRow(m)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func memberRow(_ m: GroupMember) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: m.name, size: 32)
            VStack(alignment: .leading) {
                Text(m.name)
                if m.role == "owner" {
                    Text("Owner").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let me = session.user?.uid, vm.isAdmin(uid: me), m.id != me {
                Menu {
                    if !(vm.group?.admins.contains(m.id) ?? false) {
                        Button("Promote to Admin") { Task { try? await vm.promote(uid: m.id) } }
                    } else {
                        Button("Demote from Admin", role: .destructive) { Task { try? await vm.demote(uid: m.id) } }
                    }
                    Button("Remove from Group", role: .destructive) { Task { try? await vm.remove(uid: m.id) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// Inserted PlansListView here:

struct PlansListView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme

    @StateObject private var vm = PlansVM()
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                if vm.plans.isEmpty {
                    Text("No plans yet. Tap + to create one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.plans) { plan in
                        NavigationLink(destination: PlanEditorView(planId: plan.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(plan.title).font(.headline)
                                HStack(spacing: 8) {
                                    let dateText = Text(plan.when, style: .date)
                                    Label { dateText } icon: { Image(systemName: "calendar") }
                                    let locationText: String = plan.location.isEmpty ? "TBD" : plan.location
                                    Label(locationText, systemImage: "mappin.and.ellipse")
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.globalTheme.gradient.opacity(0.06))
            .navigationTitle("Plans")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign Out") {
                        session.signOut()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .tint(theme.globalTheme.accent)
            .sheet(isPresented: $showCreate) {
                CreatePlanView { title, when, location, notes in
                    guard let uid = session.user?.uid else { return }
                    Task {
                        do {
                            _ = try await vm.createPlan(title: title, when: when, location: location, notes: notes, uid: uid)
                            print("[Plans] Create success")
                            await MainActor.run { showCreate = false }
                        } catch {
                            print("[Plans] Create failed: \(error.localizedDescription)")
                            await MainActor.run { showCreate = false }
                        }
                    }
                }
            }
            .onAppear { vm.start() }
            .onDisappear { vm.stop() }
        }
    }
}

struct PlanEditorView: View {
    let planId: String

    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm = PlanDetailVM()
    @State private var title: String = ""
    @State private var when: Date = Date()
    @State private var location: String = ""
    @State private var notes: String = ""
    @State private var isWorking = false

    private func loadFields() {
        if let p = vm.plan {
            title = p.title
            when = p.when
            location = p.location
            notes = p.notes
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("When") {
                    DatePicker("Date & Time", selection: $when, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Details") {
                    TextField("Location", text: $location)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
                if let counts = Optional(vm.counts()), vm.plan != nil {
                    Section("Votes") {
                        HStack { CountPill(icon: "checkmark.circle", label: "Yes", count: counts.yes) }
                        HStack { CountPill(icon: "questionmark.circle", label: "Maybe", count: counts.maybe) }
                        HStack { CountPill(icon: "xmark.circle", label: "No", count: counts.no) }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        guard !isWorking else { return }
                        isWorking = true
                        Task {
                            do {
                                try await PlansService().deletePlan(planId)
                                print("[Plan] Deleted id=\(planId)")
                                await MainActor.run { dismiss() }
                            } catch {
                                print("[Plan] Delete failed: \(error.localizedDescription)")
                                await MainActor.run { isWorking = false }
                            }
                        }
                    } label: {
                        Text("Delete Plan")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(theme.globalTheme.gradient.opacity(0.06))
            .tint(theme.globalTheme.accent)
            .navigationTitle("Edit Plan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isWorking ? "Saving…" : "Save") {
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let p = vm.plan, !t.isEmpty else { return }
                        isWorking = true
                        Task {
                            do {
                                try await PlansService().updatePlan(p.id, fields: [
                                    "title": t,
                                    "when": Timestamp(date: when),
                                    "location": location.trimmingCharacters(in: .whitespacesAndNewlines),
                                    "notes": notes.trimmingCharacters(in: .whitespacesAndNewlines)
                                ])
                                print("[Plan] Update success id=\(p.id)")
                                await MainActor.run { isWorking = false }
                            } catch {
                                print("[Plan] Update failed: \(error.localizedDescription)")
                                await MainActor.run { isWorking = false }
                            }
                        }
                    }
                    .disabled(isWorking || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.plan == nil)
                }
            }
            .onAppear {
                vm.start(planId: planId)
            }
            .onChange(of: vm.plan?.id) { _, _ in
                loadFields()
            }
            .onDisappear { vm.stop() }
        }
    }
}

// MARK: - Groups List View modification for CreateGroupView's new onCreate signature

struct GroupsListView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme
    @Environment(DeepLinkRouter.self) private var router

    @StateObject private var vm = GroupsVM()

    @State private var showCreate = false
    @State private var pendingNavGroupId: String?
    @State private var deepLinkActive = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Hero header
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            AvatarView(name: session.displayName, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your Groups")
                                    .font(.title3).bold()
                                Text("Manage and explore")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                print("[Groups] Plus tapped (header)")
                                showCreate = true
                            } label: {
                                Image(systemName: "plus.circle.fill").font(.title2)
                            }
                            .tint(theme.globalTheme.accent)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    LazyVStack(spacing: 14) {
                        ForEach(vm.groups) { group in
                            let groupId = group.id
                            NavigationLink(destination: GroupDetailView(groupId: groupId)) {
                                groupRow(group: group)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign Out") {
                        session.signOut()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        print("[Groups] Plus tapped (toolbar)")
                        showCreate = true
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .background(theme.globalTheme.gradient.opacity(0.06))
            .tint(theme.globalTheme.accent)
            .sheet(isPresented: $showCreate) {
                CreateGroupView { name, done in
                    guard let uid = session.user?.uid else { return }
                    Task {
                        do {
                            let newId = try await vm.createGroup(name: name, uid: uid, displayName: session.displayName)
                            print("[Groups] Create success id=\(newId)")
                            await MainActor.run {
                                pendingNavGroupId = newId
                                showCreate = false
                                done()
                            }
                        } catch {
                            print("[Groups] Create failed: \(error.localizedDescription)")
                            await MainActor.run { done() }
                        }
                    }
                }
            }
            .overlay(alignment: .center) {
                if let id = pendingNavGroupId {
                    NavigationLink(value: id) { EmptyView() }
                        .frame(width: 0, height: 0)
                        .hidden()
                        .allowsHitTesting(false)
                        .onAppear { deepLinkActive = false }
                }
            }
            .navigationDestination(for: String.self) { id in
                GroupDetailView(groupId: id)
            }
            .onAppear {
                if let uid = session.user?.uid {
                    vm.start(uid: uid)
                }
                if let id = router.consumePendingGroupId() {
                    pendingNavGroupId = id
                }
            }
            .onChange(of: router.pendingGroupId) { _, _ in
                if let id = router.consumePendingGroupId() {
                    pendingNavGroupId = id
                }
            }
        }
    }

    @ViewBuilder
    private func groupRow(group: Group) -> some View {
        let currentTheme = theme.themeForGroup(key: group.themeKey)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(currentTheme.gradient)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.white.opacity(0.9))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.headline)
                    let membersText = "Members: " + String(group.memberIds.count)
                    Text(membersText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.globalTheme.accent.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        .socialCardStyle(theme: theme.globalTheme)
    }
}

// Added Calendar tab to RootView's TabView
struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme

    var body: some View {
        SwiftUI.Group {
            if session.user != nil {
                TabView {
                    PlansListView()
                        .tabItem {
                            Label("Plans", systemImage: "list.bullet.rectangle")
                        }

                    GroupsListView()
                        .tabItem {
                            Label("Groups", systemImage: "person.3")
                        }
                    
                    CalendarView()
                        .tabItem {
                            Label("Calendar", systemImage: "calendar")
                        }
                    
                    AccountSettingsView()
                        .tabItem {
                            Label("Account", systemImage: "person.crop.circle")
                        }
                }
                .tint(theme.globalTheme.accent)
            } else {
                AuthView()
            }
        }
    }
}

// MARK: - Calendar (All Plans + Global Availability)

@MainActor
final class CalendarVM: ObservableObject {
    @Published var plans: [Plan] = []
    @Published var myGroups: [Group] = []
    @Published var allAvailability: [GroupAvailability] = [] // union across groups
    @Published var error: String?

    private let plansService = PlansService()
    private let groupsService = GroupsService()

    private var plansListener: ListenerRegistration?
    private var groupListener: ListenerRegistration?
    private var availabilityListeners: [String: ListenerRegistration] = [:]

    func start(uid: String) {
        stop()
        // Listen to all plans (existing query)
        plansListener = plansService.plansQuery().addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err { self.error = err.localizedDescription; return }
            let docs = snap?.documents ?? []
            self.plans = docs.map { Plan(id: $0.documentID, data: $0.data()) }
        }
        // Listen to groups the user belongs to
        groupListener = groupsService.groupsQuery(for: uid).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err { self.error = err.localizedDescription; return }
            let docs = snap?.documents ?? []
            let groups = docs.map { Group(id: $0.documentID, data: $0.data()) }
            self.myGroups = groups
            // Rewire availability listeners per group
            self.availabilityListeners.values.forEach { $0.remove() }
            self.availabilityListeners.removeAll()
            // Collect availability for all groups and merge
            var combined: [String: GroupAvailability] = [:]
            for g in groups {
                let l = self.groupsService.availabilityRef(g.id).addSnapshotListener { [weak self] snap, err in
                    guard let self else { return }
                    if let err = err { self.error = err.localizedDescription; return }
                    let docs = snap?.documents ?? []
                    let avail = docs.map { GroupAvailability(id: $0.documentID, data: $0.data()) }
                    // Merge into combined map by user id
                    var map = combined
                    for a in avail {
                        if var existing = map[a.id] {
                            existing = GroupAvailability(id: existing.id, data: [
                                "name": existing.name,
                                "freeDates": Array(existing.freeDates.union(a.freeDates))
                            ])
                            map[a.id] = existing
                        } else {
                            map[a.id] = a
                        }
                    }
                    // Rebuild allAvailability from map
                    self.allAvailability = Array(map.values)
                }
                self.availabilityListeners[g.id] = l
            }
        }
    }

    func stop() {
        plansListener?.remove(); plansListener = nil
        groupListener?.remove(); groupListener = nil
        availabilityListeners.values.forEach { $0.remove() }
        availabilityListeners.removeAll()
    }

    // Persist my free dates to all groups I'm in
    func saveMyAvailabilityToAllGroups(uid: String, name: String, freeDates: Set<String>) async {
        for g in myGroups {
            do {
                try await groupsService.setAvailability(groupId: g.id, uid: uid, name: name, freeDates: freeDates)
            } catch {
                // accumulate minimal error; continue best-effort
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    var topDates: [(date: Date, count: Int)] {
        var counts: [String: Int] = [:]
        for a in allAvailability {
            for iso in a.freeDates { counts[iso, default: 0] += 1 }
        }
        var items: [(Date, Int)] = []
        items.reserveCapacity(counts.count)
        for (iso, c) in counts {
            if let d = CalendarView.isoFormatter.date(from: iso) {
                items.append((d, c))
            }
        }
        items.sort { (lhs, rhs) -> Bool in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        return items.map { (date: $0.0, count: $0.1) }
    }
}

struct CalendarView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme

    @StateObject private var vm = CalendarVM()
    @State private var selection: Set<DateComponents> = []
    @State private var isSaving = false

    // ISO yyyy-MM-dd formatter shared with availability views
    fileprivate static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func comps(from date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }
    private func date(from comps: DateComponents) -> Date? { Calendar.current.date(from: comps) }
    private func iso(from comps: DateComponents) -> String? { guard let d = date(from: comps) else { return nil }; return Self.isoFormatter.string(from: d) }

    // Plan dates for highlighting
    private var planDates: Set<DateComponents> {
        Set(vm.plans.map { comps(from: $0.when) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Calendar
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your availability (all groups)")
                            .font(.headline)
                        Text("Pick the days you're free. We'll share them with each group you belong to.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    MultiDatePicker("Select Dates", selection: $selection)
                        .padding(.horizontal)
                        .overlay(CalendarPlanLegend(accent: theme.globalTheme.accent))

                    // Upcoming plans
                    if !vm.plans.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Upcoming Plans")
                                .font(.subheadline.bold())
                                .padding(.horizontal)
                            let sortedPlans: [Plan] = vm.plans.sorted { lhs, rhs in lhs.when < rhs.when }
                            ForEach(sortedPlans) { plan in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(plan.title).font(.body)
                                        HStack(spacing: 8) {
                                            Image(systemName: "calendar").font(.caption)
                                            Text(plan.when, style: .date)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if planDates.contains(comps(from: plan.when)) {
                                        Image(systemName: "circle.fill")
                                            .foregroundStyle(theme.globalTheme.accent)
                                            .font(.caption2)
                                    }
                                }
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                )
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Top free dates across all groups
                    if !vm.topDates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top Free Dates (All Groups)")
                                .font(.subheadline.bold())
                                .padding(.horizontal)
                            let topItems: [(date: Date, count: Int)] = Array(vm.topDates.prefix(10))
                            let enumeratedItems: [(offset: Int, element: (date: Date, count: Int))] = Array(topItems.enumerated())
                            ForEach(enumeratedItems, id: \.offset) { item in
                                let dateValue: Date = item.element.date
                                let countValue: Int = item.element.count
                                let countText: String = String(countValue) + " free"
                                HStack {
                                    Text(dateValue, style: .date)
                                    Spacer()
                                    Text(countText)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(theme.globalTheme.gradient.opacity(0.06))
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving…" : "Save Availability") {
                        guard let uid = session.user?.uid else { return }
                        isSaving = true
                        let freeDates: Set<String> = Set(selection.compactMap { iso(from: $0) })
                        Task {
                            await vm.saveMyAvailabilityToAllGroups(uid: uid, name: session.displayName, freeDates: freeDates)
                            await MainActor.run { isSaving = false }
                        }
                    }
                    .disabled(isSaving || session.user?.uid == nil)
                }
            }
            .tint(theme.globalTheme.accent)
            .themedToolbarBackground(theme.globalTheme)
            .onAppear {
                if let uid = session.user?.uid { vm.start(uid: uid) }
            }
            .onDisappear { vm.stop() }
        }
    }
}

struct CalendarPlanLegend: View {
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(accent)
                    .font(.caption2)
                Text("Days with plans are highlighted in the list below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 220)
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var working: Bool = false
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact Information") {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(working ? "Saving…" : "Save Changes") {
                        working = true
                        Task {
                            await session.updateContactInfo(displayName: name, email: email)
                            await MainActor.run { working = false }
                        }
                    }
                    .disabled(working)
                }

                Section("Danger Zone") {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("Delete Account")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(theme.globalTheme.gradient.opacity(0.06))
            .tint(theme.globalTheme.accent)
            .navigationTitle("Account")
            .toolbar { }
            .onAppear {
                name = session.displayName
                email = session.user?.email ?? ""
            }
            .alert("Delete Account?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task { await session.deleteAccountPermanently() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action will permanently delete your account and cannot be undone.")
            }
        }
    }
}

// The rest of the file remains unchanged...

struct CountPill: View {
    let icon: String
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text("\(label): \(count)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 3)
        .clipShape(Capsule())
    }
}

struct AvatarView: View {
    let name: String
    let size: CGFloat

    private var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.2))
            Text(initials).font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Group Models

struct Group: Identifiable {
    let id: String
    var name: String
    var createdBy: String
    var createdAt: Date
    var memberIds: [String]
    var themeKey: String
    var admins: [String] // uid list of admins
    var joinRequests: [String] // uid list requesting to join
    var invites: [String] // uid list of invited users (legacy)
    var inviteCode: String? // sharable code

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = data["name"] as? String ?? ""
        self.createdBy = data["createdBy"] as? String ?? ""
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.memberIds = data["memberIds"] as? [String] ?? []
        self.themeKey = data["themeKey"] as? String ?? ""
        self.admins = data["admins"] as? [String] ?? []
        self.joinRequests = data["joinRequests"] as? [String] ?? []
        self.invites = data["invites"] as? [String] ?? []
        self.inviteCode = data["inviteCode"] as? String
    }

    var toFirestore: [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "createdBy": createdBy,
            "createdAt": Timestamp(date: createdAt),
            "memberIds": memberIds,
            "admins": admins,
            "joinRequests": joinRequests,
            "invites": invites
        ]
        if !themeKey.isEmpty {
            dict["themeKey"] = themeKey
        }
        if let inviteCode { dict["inviteCode"] = inviteCode }
        return dict
    }
}

struct GroupMember: Identifiable {
    let id: String // uid
    let name: String
    let joinedAt: Date
    let role: String

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = data["name"] as? String ?? "Someone"
        self.joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue() ?? Date()
        self.role = data["role"] as? String ?? "member"
    }
}

// Inserted GroupAvailability model here:

struct GroupAvailability: Identifiable, Equatable, Hashable {
    let id: String // uid
    let name: String
    let freeDates: Set<String> // ISO yyyy-MM-dd

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = data["name"] as? String ?? "Someone"
        let arr = data["freeDates"] as? [String] ?? []
        self.freeDates = Set(arr)
    }

    static func == (lhs: GroupAvailability, rhs: GroupAvailability) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.freeDates == rhs.freeDates
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(freeDates)
    }
}

// MARK: - Groups Service

final class GroupsService {
    private let db = Firestore.firestore()
    private let users = UsersService()
    private func fetchGroupName(_ groupId: String) async throws -> String? {
        let snap = try await groupRef(groupId).getDocument()
        return snap.data()?["name"] as? String
    }

    func groupsQuery(for uid: String) -> Query {
        db.collection("groups")
            .whereField("memberIds", arrayContains: uid)
            .limit(to: 50)
    }

    func groupRef(_ groupId: String) -> DocumentReference {
        db.collection("groups").document(groupId)
    }

    func membersRef(_ groupId: String) -> CollectionReference {
        db.collection("groups").document(groupId).collection("members")
    }

    func createGroup(name: String, uid: String, displayName: String) async throws -> String {
        let id = UUID().uuidString
        let code = String(UUID().uuidString.prefix(6)).uppercased()
        let data: [String: Any] = [
            "name": name,
            "createdBy": uid,
            "createdAt": Timestamp(date: Date()),
            "memberIds": [uid],
            "admins": [uid],
            "joinRequests": [],
            "invites": [],
            "inviteCode": code
        ]
        try await groupRef(id).setData(data)
        try await membersRef(id).document(uid).setData([
            "name": displayName,
            "joinedAt": Timestamp(date: Date()),
            "role": "owner"
        ], merge: true)
        try await users.linkGroup(uid: uid, groupId: id, role: "owner", groupName: name)
        return id
    }

    func joinGroup(groupId: String, uid: String, name: String) async throws {
        try await groupRef(groupId).updateData([
            "memberIds": FieldValue.arrayUnion([uid])
        ])
        try await membersRef(groupId).document(uid).setData([
            "name": name,
            "joinedAt": Timestamp(date: Date()),
            "role": "member"
        ], merge: true)
        let groupName = try await fetchGroupName(groupId)
        try await users.linkGroup(uid: uid, groupId: groupId, role: "member", groupName: groupName)
    }

    func updateGroupTheme(groupId: String, themeKey: String) async throws {
        try await groupRef(groupId).updateData([
            "themeKey": themeKey
        ])
    }

    func promoteToAdmin(groupId: String, uid: String) async throws {
        try await groupRef(groupId).updateData([
            "admins": FieldValue.arrayUnion([uid])
        ])
        try await membersRef(groupId).document(uid).setData(["role": "admin"], merge: true)
    }

    func demoteAdmin(groupId: String, uid: String) async throws {
        try await groupRef(groupId).updateData([
            "admins": FieldValue.arrayRemove([uid])
        ])
        try await membersRef(groupId).document(uid).setData(["role": "member"], merge: true)
    }

    func inviteUser(groupId: String, uid: String) async throws {
        try await groupRef(groupId).updateData([
            "invites": FieldValue.arrayUnion([uid])
        ])
    }

    func requestToJoin(groupId: String, uid: String, name: String) async throws {
        try await groupRef(groupId).updateData([
            "joinRequests": FieldValue.arrayUnion([uid])
        ])
        try await membersRef(groupId).document(uid).setData([
            "name": name,
            "joinedAt": Timestamp(date: Date()),
            "role": "pending"
        ], merge: true)
    }

    func approveJoinRequest(groupId: String, uid: String, name: String) async throws {
        let groupName = try await fetchGroupName(groupId)
        try await groupRef(groupId).updateData([
            "joinRequests": FieldValue.arrayRemove([uid]),
            "memberIds": FieldValue.arrayUnion([uid])
        ])
        try await membersRef(groupId).document(uid).setData([
            "name": name,
            "joinedAt": Timestamp(date: Date()),
            "role": "member"
        ], merge: true)
        try await users.linkGroup(uid: uid, groupId: groupId, role: "member", groupName: groupName)
    }

    func denyJoinRequest(groupId: String, uid: String) async throws {
        try await groupRef(groupId).updateData([
            "joinRequests": FieldValue.arrayRemove([uid])
        ])
        try await membersRef(groupId).document(uid).delete()
    }

    func removeMember(groupId: String, uid: String) async throws {
        try await groupRef(groupId).updateData([
            "memberIds": FieldValue.arrayRemove([uid]),
            "admins": FieldValue.arrayRemove([uid])
        ])
        try await membersRef(groupId).document(uid).delete()
        try? await users.unlinkGroup(uid: uid, groupId: groupId)
    }

    func regenerateInviteCode(groupId: String) async throws -> String {
        let code = String(UUID().uuidString.prefix(6)).uppercased()
        try await groupRef(groupId).updateData(["inviteCode": code])
        return code
    }

    func joinGroup(usingCode code: String, uid: String, name: String) async throws {
        // Find group by inviteCode
        let snap = try await db.collection("groups").whereField("inviteCode", isEqualTo: code.uppercased()).limit(to: 1).getDocuments()
        guard let doc = snap.documents.first else { throw NSError(domain: "Invite", code: 404, userInfo: [NSLocalizedDescriptionKey: "Invalid code"]) }
        let groupId = doc.documentID
        let groupName = doc.data()["name"] as? String
        try await groupRef(groupId).updateData([
            "memberIds": FieldValue.arrayUnion([uid])
        ])
        try await membersRef(groupId).document(uid).setData([
            "name": name,
            "joinedAt": Timestamp(date: Date()),
            "role": "member"
        ], merge: true)
        try await users.linkGroup(uid: uid, groupId: groupId, role: "member", groupName: groupName)
    }

    func availabilityRef(_ groupId: String) -> CollectionReference {
        db.collection("groups").document(groupId).collection("availability")
    }

    func setAvailability(groupId: String, uid: String, name: String, freeDates: Set<String>) async throws {
        try await availabilityRef(groupId).document(uid).setData([
            "name": name,
            "freeDates": Array(freeDates)
        ], merge: true)
        try await users.recordAvailability(uid: uid, groupId: groupId, freeDates: freeDates)
    }
}

// MARK: - Groups ViewModels

@MainActor
final class GroupsVM: ObservableObject {
    @Published var groups: [Group] = []
    @Published var error: String?

    private let service = GroupsService()
    private var listener: ListenerRegistration?

    func start(uid: String) {
        listener?.remove()
        listener = service.groupsQuery(for: uid).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err {
                self.error = err.localizedDescription
                print("[Groups] Listener error: \(err.localizedDescription)")
                return
            }
            let docs = snap?.documents ?? []
            self.groups = docs.map { Group(id: $0.documentID, data: $0.data()) }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    func createGroup(name: String, uid: String, displayName: String) async throws -> String {
        try await service.createGroup(name: name, uid: uid, displayName: displayName)
    }
}

@MainActor
final class GroupDetailVM: ObservableObject {
    @Published var group: Group?
    @Published var members: [GroupMember] = []
    @Published var error: String?

    // Added availability published property
    @Published var availability: [GroupAvailability] = []

    let service = GroupsService()
    private var groupListener: ListenerRegistration?
    private var membersListener: ListenerRegistration?

    // Added availability listener
    private var availabilityListener: ListenerRegistration?

    func start(groupId: String) {
        stop()
        groupListener = service.groupRef(groupId).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err {
                self.error = err.localizedDescription
                print("[Group] Listener error (group): \(err.localizedDescription)")
                return
            }
            guard let data = snap?.data() else { return }
            self.group = Group(id: groupId, data: data)
        }
        membersListener = service.membersRef(groupId).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err {
                self.error = err.localizedDescription
                print("[Group] Listener error (members): \(err.localizedDescription)")
                return
            }
            let docs = snap?.documents ?? []
            self.members = docs.map { GroupMember(id: $0.documentID, data: $0.data()) }
        }
        // Added availability listener setup
        availabilityListener = service.availabilityRef(groupId).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err = err {
                self.error = err.localizedDescription
                print("[Group] Listener error (availability): \(err.localizedDescription)")
                return
            }
            let docs = snap?.documents ?? []
            self.availability = docs.map { GroupAvailability(id: $0.documentID, data: $0.data()) }
        }
    }

    func stop() {
        groupListener?.remove()
        membersListener?.remove()
        availabilityListener?.remove()
        groupListener = nil
        membersListener = nil
        availabilityListener = nil
    }

    func joinGroup(groupId: String, uid: String, name: String) async throws {
        try await service.joinGroup(groupId: groupId, uid: uid, name: name)
    }

    func isMember(uid: String) -> Bool {
        guard let group else { return false }
        return group.memberIds.contains(uid)
    }

    func isAdmin(uid: String) -> Bool {
        guard let group else { return false }
        return group.admins.contains(uid)
    }

    func promote(uid: String) async throws {
        try await service.promoteToAdmin(groupId: group?.id ?? "", uid: uid)
    }

    func demote(uid: String) async throws {
        try await service.demoteAdmin(groupId: group?.id ?? "", uid: uid)
    }

    func invite(uid: String) async throws {
        try await service.inviteUser(groupId: group?.id ?? "", uid: uid)
    }

    func approve(uid: String, name: String) async throws {
        try await service.approveJoinRequest(groupId: group?.id ?? "", uid: uid, name: name)
    }

    func deny(uid: String) async throws {
        try await service.denyJoinRequest(groupId: group?.id ?? "", uid: uid)
    }

    func remove(uid: String) async throws {
        try await service.removeMember(groupId: group?.id ?? "", uid: uid)
    }

    func regenerateCode() async throws -> String {
        try await service.regenerateInviteCode(groupId: group?.id ?? "")
    }

    func joinWithCode(_ code: String, uid: String, name: String) async throws {
        try await service.joinGroup(usingCode: code, uid: uid, name: name)
    }

    // Added availability setter
    func setMyAvailability(groupId: String, uid: String, name: String, freeDates: Set<String>) async throws {
        try await service.setAvailability(groupId: groupId, uid: uid, name: name, freeDates: freeDates)
    }
}

// MARK: - AuthView Inserted as requested

struct AuthView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isWorking: Bool = false
    @State private var isSignUpMode: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(theme.globalTheme.accent)
                    Text("FlashPlan")
                        .font(.largeTitle).bold()
                }
                .padding(.bottom, 10)

                VStack(spacing: 12) {
                    if isSignUpMode {
                        TextField("Name", text: $name)
                            .textContentType(.name)
                            .autocapitalization(.words)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)

                if let err = session.authError, !err.isEmpty {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Button(isWorking ? (isSignUpMode ? "Creating…" : "Signing in…") : (isSignUpMode ? "Create Account" : "Sign In")) {
                    let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    let p = password
                    guard !e.isEmpty, !p.isEmpty else { return }
                    isWorking = true
                    Task {
                        do {
                            if isSignUpMode {
                                await session.signUp(email: e, password: p, displayName: name)
                            } else {
                                await session.signIn(email: e, password: p)
                            }
                        }
                        await MainActor.run { isWorking = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.globalTheme.accent)
                .disabled(
                    isWorking ||
                    email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    password.isEmpty ||
                    (isSignUpMode && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
                .padding(.horizontal)

                Button(isSignUpMode ? "Have an account? Sign In" : "New here? Create Account") {
                    withAnimation { isSignUpMode.toggle() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.globalTheme.gradient.opacity(0.06))
            .navigationTitle(isSignUpMode ? "Create Account" : "Sign In")
            .toolbar { }
        }
    }
}

// MARK: - Groups Views

struct GroupAvailabilityView: View {
    let groupId: String

    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm = GroupDetailVM()
    @State private var selection: Set<DateComponents> = []
    @State private var isSaving = false

    // ISO yyyy-MM-dd formatter for storing dates as strings
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func components(from iso: String) -> DateComponents? {
        guard let date = Self.isoFormatter.date(from: iso) else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    private func isoString(from comps: DateComponents) -> String? {
        guard let date = Calendar.current.date(from: comps) else { return nil }
        return Self.isoFormatter.string(from: date)
    }

    private func updateSelectionFromVM() {
        guard let uid = session.user?.uid else { return }
        if let me = vm.availability.first(where: { $0.id == uid }) {
            let comps = me.freeDates.compactMap(components(from:))
            selection = Set(comps)
        }
    }

    private var topDates: [(id: String, date: Date, count: Int)] {
        var counts: [String: Int] = [:]
        for a in vm.availability {
            for iso in a.freeDates {
                counts[iso, default: 0] += 1
            }
        }
        let items: [(id: String, date: Date, count: Int)] = counts.compactMap { (iso, count) in
            guard let date = Self.isoFormatter.date(from: iso) else { return nil }
            return (id: iso, date: date, count: count)
        }
        return items.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.date < rhs.date
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mark the days you're free")
                            .font(.headline)
                        Text("We'll show which dates work best for the group.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    
                    MultiDatePicker("Select Dates", selection: $selection)
                        .padding(.horizontal)

                    if !topDates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top dates")
                                .font(.subheadline.bold())
                                .padding(.horizontal)
                            let items: [(id: String, date: Date, count: Int)] = Array(topDates.prefix(10))
                            let enumeratedItems: [(offset: Int, element: (id: String, date: Date, count: Int))] = Array(items.enumerated())
                            ForEach(enumeratedItems, id: \.offset) { item in
                                HStack {
                                    Text(item.element.date, style: .date)
                                    Spacer()
                                    Text("\(item.element.count) free")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(theme.globalTheme.gradient.opacity(0.06))
            .navigationTitle("Availability")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving…" : "Save") {
                        guard let uid = session.user?.uid else { return }
                        isSaving = true
                        let freeDates: Set<String> = Set(selection.compactMap { isoString(from: $0) })
                        Task {
                            do {
                                try await vm.setMyAvailability(groupId: groupId, uid: uid, name: session.displayName, freeDates: freeDates)
                                print("[Availability] Save success")
                                await MainActor.run {
                                    isSaving = false
                                    dismiss()
                                }
                            } catch {
                                print("[Availability] Save failed: \(error.localizedDescription)")
                                await MainActor.run { isSaving = false }
                            }
                        }
                    }
                    .disabled(isSaving || session.user?.uid == nil)
                }
            }
            .tint(theme.globalTheme.accent)
            .themedToolbarBackground(theme.globalTheme)
            .onAppear {
                vm.start(groupId: groupId)
                updateSelectionFromVM()
            }
            .onChange(of: vm.availability) { _, _ in
                // If selection is empty (first load), prefill from backend
                if selection.isEmpty { updateSelectionFromVM() }
            }
        }
    }
}

// Inserted GroupFreeCalendarView here:

struct GroupFreeCalendarView: View {
    let membersCount: Int
    let availability: [GroupAvailability]

    @Environment(AppThemeManager.self) private var theme

    // Reuse ISO formatter
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @State private var dummySelection: Set<DateComponents> = [] // MultiDatePicker requires a binding

    private func iso(from comps: DateComponents) -> String? {
        guard let d = Calendar.current.date(from: comps) else { return nil }
        return Self.isoFormatter.string(from: d)
    }

    private func components(from iso: String) -> DateComponents? {
        guard let date = Self.isoFormatter.date(from: iso) else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    // Map of date components to count of free members
    private var freeCounts: [DateComponents: Int] {
        var counts: [DateComponents: Int] = [:]
        for a in availability {
            for iso in a.freeDates {
                if let comps = components(from: iso) {
                    counts[comps, default: 0] += 1
                }
            }
        }
        return counts
    }

    // Decide color for a given day
    private func color(for comps: DateComponents) -> Color? {
        guard membersCount > 0, let count = freeCounts[comps] else { return nil }
        if count == membersCount {
            return Color.green
        }
        if count * 2 > membersCount { // > 50%
            return Color.blue
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group Free Days")
                .font(.headline)
                .padding(.horizontal, 4)
            MultiDatePicker("", selection: $dummySelection)
                .overlay(
                    GeometryReader { proxy in
                        // We can't directly access day cells, so provide a legend instead
                        // and keep the calendar context nearby. To visually indicate,
                        // we provide a compact legend and rely on the list below for counts.
                        Color.clear
                    }
                )
            // Small legend
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                    Text("Everyone free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(Color.blue).frame(width: 10, height: 10)
                    Text("> 50% free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            // Top free dates for this group
            let itemsMap: [String: Int] = {
                var map: [String: Int] = [:]
                for a in availability {
                    for iso in a.freeDates { map[iso, default: 0] += 1 }
                }
                return map
            }()
            let unsortedItems: [(date: Date, count: Int)] = itemsMap.compactMap { (iso, c) in
                guard let d = Self.isoFormatter.date(from: iso) else { return nil }
                return (date: d, count: c)
            }
            let items: [(date: Date, count: Int)] = unsortedItems.sorted { l, r in
                if l.count != r.count { return l.count > r.count }
                return l.date < r.date
            }

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Best dates for this group")
                        .font(.subheadline.bold())
                    let topItems: [(date: Date, count: Int)] = Array(items.prefix(10))
                    let enumeratedTopItems: [(offset: Int, element: (date: Date, count: Int))] = Array(topItems.enumerated())
                    ForEach(enumeratedTopItems, id: \.offset) { item in
                        HStack {
                            Text(item.element.date, style: .date)
                            Spacer()
                            let c = item.element.count
                            if membersCount > 0 && c == membersCount {
                                Text("Everyone free")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if membersCount > 0 && c * 2 > membersCount {
                                Text("> 50% free")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            } else {
                                Text("\(c)/\(membersCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                Text("No availability shared yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .background(theme.globalTheme.gradient.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// Assuming the added GroupThemePicker struct somewhere here:

struct GroupThemePicker: View {
    let group: Group
    let vm: GroupDetailVM
    let currentKey: String
    let onDone: () -> Void

    @Environment(AppThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKey: String
    @State private var isSaving = false

    init(group: Group, vm: GroupDetailVM, currentKey: String, onDone: @escaping () -> Void) {
        self.group = group
        self.vm = vm
        self.currentKey = currentKey
        self.onDone = onDone
        _selectedKey = State(initialValue: currentKey)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(ThemeCatalog.all, id: \.key) { th in
                        Button {
                            selectedKey = th.key
                        } label: {
                            GroupThemeRow(theme: th, isSelected: th.key == selectedKey)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(theme.globalTheme.gradient.opacity(0.06))
            .navigationTitle("Group Theme")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDone() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving…" : "Save") {
                        isSaving = true
                        Task {
                            do {
                                if selectedKey != currentKey {
                                    try await vm.service.updateGroupTheme(groupId: group.id, themeKey: selectedKey)
                                }
                                await MainActor.run {
                                    isSaving = false
                                    onDone()
                                }
                            } catch {
                                await MainActor.run {
                                    isSaving = false
                                }
                            }
                        }
                    }
                    .disabled(isSaving || selectedKey == currentKey)
                }
            }
            .tint(theme.globalTheme.accent)
            .themedToolbarBackground(theme.globalTheme)
        }
    }
}
private struct GroupThemeRow: View {
    let theme: AppTheme
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.gradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "paintbrush.fill")
                        .foregroundStyle(.white.opacity(0.9))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.key.capitalized)
                    .font(.headline)
                if isSelected {
                    Text("Selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.accent)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}


struct InviteCodeView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme

    let vm: GroupDetailVM
    var onDismiss: () -> Void

    @State private var enteredCode: String = ""
    @State private var isWorking: Bool = false
    @State private var localCode: String?

    private var isAdmin: Bool {
        guard let me = session.user?.uid else { return false }
        return vm.isAdmin(uid: me)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAdmin {
                    Section("Invite Code") {
                        Text(localCode ?? (vm.group?.inviteCode ?? "—"))
                            .font(.title)
                            .monospaced()
                        Button(isWorking ? "Regenerating…" : "Regenerate Code") {
                            isWorking = true
                            Task {
                                do {
                                    let newCode = try await vm.regenerateCode()
                                    print("[Invite] Regenerated code: \(newCode)")
                                    await MainActor.run {
                                        localCode = newCode
                                        isWorking = false
                                    }
                                } catch {
                                    print("[Invite] Regenerate failed: \(error.localizedDescription)")
                                    await MainActor.run {
                                        isWorking = false
                                    }
                                }
                            }
                        }
                        .disabled(isWorking)
                    }
                } else {
                    Section("Enter Invite Code") {
                        TextField("ABC123", text: $enteredCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .tint(theme.globalTheme.accent)
            .navigationTitle(isAdmin ? "Invite Code" : "Join with Code")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { onDismiss() }
                }
                if !isAdmin {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isWorking ? "Joining…" : "Join") {
                            let code = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !code.isEmpty, let uid = session.user?.uid else { return }
                            isWorking = true
                            Task {
                                do {
                                    try await vm.joinWithCode(code, uid: uid, name: session.displayName)
                                    print("[Invite] Join with code success")
                                    await MainActor.run {
                                        isWorking = false
                                        onDismiss()
                                    }
                                } catch {
                                    print("[Invite] Join with code failed: \(error.localizedDescription)")
                                    await MainActor.run {
                                        isWorking = false
                                    }
                                }
                            }
                        }
                        .disabled(isWorking || enteredCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.user?.uid == nil)
                    }
                }
            }
            .themedToolbarBackground(theme.globalTheme)
        }
    }
}

struct RequestsView: View {
    let groupId: String

    @EnvironmentObject var session: SessionStore
    @Environment(AppThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm = GroupDetailVM()
    @State private var working: Set<String> = []

    private func memberName(for uid: String) -> String {
        vm.members.first(where: { $0.id == uid })?.name ?? "Member"
    }

    var body: some View {
        NavigationStack {
            List {
                if let group = vm.group {
                    if group.joinRequests.isEmpty {
                        Text("No pending requests")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(group.joinRequests, id: \.self) { uid in
                            HStack(spacing: 12) {
                                AvatarView(name: memberName(for: uid), size: 32)
                                Text(memberName(for: uid))
                                Spacer()
                                HStack(spacing: 8) {
                                    Button("Approve") {
                                        Task { await approve(uid: uid, name: memberName(for: uid)) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(theme.globalTheme.accent)
                                    .disabled(working.contains(uid))

                                    Button("Deny", role: .destructive) {
                                        Task { await deny(uid: uid) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(working.contains(uid))
                                }
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.globalTheme.gradient.opacity(0.06))
            .navigationTitle("Requests")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .tint(theme.globalTheme.accent)
            .themedToolbarBackground(theme.globalTheme)
            .onAppear { vm.start(groupId: groupId) }
            .onDisappear { vm.stop() }
        }
    }

    private func approve(uid: String, name: String) async {
        working.insert(uid)
        defer { working.remove(uid) }
        do {
            try await vm.approve(uid: uid, name: name)
            print("[Requests] Approved uid=\(uid)")
        } catch {
            print("[Requests] Approve failed uid=\(uid): \(error.localizedDescription)")
            // Optionally handle error
        }
    }

    private func deny(uid: String) async {
        working.insert(uid)
        defer { working.remove(uid) }
        do {
            try await vm.deny(uid: uid)
            print("[Requests] Denied uid=\(uid)")
        } catch {
            print("[Requests] Deny failed uid=\(uid): \(error.localizedDescription)")
            // Optionally handle error
        }
    }
}




