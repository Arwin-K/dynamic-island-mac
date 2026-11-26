import SwiftUI

/// The full request and the two buttons. Shown at the top of the agent list.
struct ApprovalCard: View {
    let module: AgentsModule
    let request: ApprovalCenter.Pending
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        let provider = module.provider(request.providerID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider, size: 12)
                Text("\(provider?.displayName ?? "Agent") wants to use \(request.toolName)")
                    .font(theme.font(size: theme.typography.bodySize, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(max(0, Int(request.expiresAt.timeIntervalSince(context.date))))s")
                        .font(theme.timerFont)
                        .foregroundStyle(palette.secondary)
                }
                .accessibilityLabel("Time left to decide")
            }
            Text(request.projectName)
                .font(theme.captionFont)
                .foregroundStyle(palette.secondary)
            ScrollView {
                Text(request.input.isEmpty ? "(no input)" : request.input)
                    .font(.system(size: max(9, theme.typography.captionSize - 0.5), design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 64)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.foreground.opacity(0.08)))
            .accessibilityLabel("Tool input: \(request.input)")
            HStack {
                Text("If you don't decide, \(provider?.displayName ?? "the agent") asks in the terminal as usual.")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.secondary)
                Spacer()
                Button {
                    module.decide(request, .deny(message: "Denied from DynamicIsland4Mac."))
                } label: {
                    Text("Deny").padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
                .accessibilityLabel("Deny \(request.toolName)")
                Button {
                    module.decide(request, .allow)
                } label: {
                    Text("Allow").padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                }
                .accessibilityLabel("Allow \(request.toolName)")
            }
            .buttonStyle(.plain)
            .font(theme.font(size: theme.typography.captionSize, weight: .semibold))
            .foregroundStyle(.white)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.7), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// The sticky alert. Deliberately has no Allow button: the full input must be seen first,
/// so clicking it opens the island on the card above.
struct ApprovalAlertView: View {
    let module: AgentsModule
    let requestID: UUID
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        if let request = module.approvals.pending.first(where: { $0.id == requestID }) {
            let provider = module.provider(request.providerID)
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(provider?.displayName ?? "Agent") wants to use \(request.toolName)")
                        .font(theme.titleFont)
                        .lineLimit(1)
                    Text("\(request.projectName) · click to review")
                        .font(theme.captionFont)
                        .foregroundStyle(palette.secondary)
                }
                Spacer()
                ProviderIcon(provider: provider, size: 14)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the request so you can allow or deny it")
        }
    }
}
