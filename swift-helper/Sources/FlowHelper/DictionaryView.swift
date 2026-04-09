// Dictionary management tab — boost terms + replacement rules.

import SwiftUI

struct DictionaryView: View {
    @ObservedObject var store = DictStore.shared
    @State private var newBoost: String = ""
    @State private var newWrong: String = ""
    @State private var newRight: String = ""
    @State private var pendingBoostDelete: BoostTerm? = nil
    @State private var pendingReplDelete: Replacement? = nil
    @State private var showBoostAlert = false
    @State private var showReplAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header("DICTIONARY", count: nil)

                section("BOOST WORDS — preserved verbatim during cleanup",
                        count: store.boosts.count)
                Text("Passed to the cleanup LLM as vocabulary; Parakeet ASR " +
                     "ignores them (only Qwen3-ASR accuracy mode consumes " +
                     "boost terms directly). Capped at 200 terms.")
                    .font(.bbSmall).foregroundColor(.bbDim)
                    .padding(.horizontal, 14).padding(.top, 6)
                boostList
                addBoostRow

                section("REPLACEMENT RULES — auto-fix common mishearings",
                        count: store.replacements.count)
                replacementList
                addReplacementRow
            }
        }
        .background(Color.bbBlack)
        .alert("Delete boost term?",
               isPresented: $showBoostAlert,
               presenting: pendingBoostDelete) { b in
            Button("Delete", role: .destructive) {
                _ = store.deleteBoost(b.term)
                pendingBoostDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingBoostDelete = nil }
        } message: { b in
            Text(b.term)
        }
        .alert("Delete replacement rule?",
               isPresented: $showReplAlert,
               presenting: pendingReplDelete) { r in
            Button("Delete", role: .destructive) {
                _ = store.deleteReplacement(r.wrong)
                pendingReplDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingReplDelete = nil }
        } message: { r in
            Text("\(r.wrong) → \(r.right)")
        }
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title).font(.bbHeader).foregroundColor(.bbAmber)
            if let c = count {
                Text("(\(c))").font(.bbSmall).foregroundColor(.bbDim)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.04))
    }

    private func section(_ title: String, count: Int) -> some View {
        VStack(spacing: 0) {
            Divider().background(Color.bbBorder)
            HStack {
                Text(title).font(.bbHeader).foregroundColor(.bbAmber)
                Text("(\(count))").font(.bbSmall).foregroundColor(.bbDim)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.03))
            Divider().background(Color.bbBorder)
        }
    }

    private var boostList: some View {
        VStack(spacing: 0) {
            if store.boosts.isEmpty {
                Text("no boost terms yet")
                    .font(.bbBody).foregroundColor(.bbDim)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(store.boosts) { b in
                HStack {
                    Text(b.term)
                        .font(.bbBody).foregroundColor(.bbCyan)
                    Spacer()
                    Button(action: {
                        pendingBoostDelete = b
                        showBoostAlert = true
                    }) {
                        Text("×")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.bbRed)
                            .frame(width: 40)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider().background(Color.bbBorder)
            }
        }
    }

    private var addBoostRow: some View {
        HStack(spacing: 10) {
            Text("ADD:").font(.bbSmall).foregroundColor(.bbDim)
            TextField("", text: $newBoost)
                .textFieldStyle(.plain)
                .font(.bbBody).foregroundColor(.bbCyan)
                .padding(6)
                .background(Color(white: 0.06))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbBorder, lineWidth: 1))
            Button(action: {
                if store.addBoost(newBoost) { newBoost = "" }
            }) {
                Text("+ ADD")
                    .font(.bbHeader).foregroundColor(.bbAmber)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbAmber, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color(white: 0.03))
    }

    private var replacementList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("WRONG").font(.bbSmall).foregroundColor(.bbDim)
                    .frame(width: 220, alignment: .leading)
                Text("→  RIGHT").font(.bbSmall).foregroundColor(.bbDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 40)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color(white: 0.03))
            Divider().background(Color.bbBorder)

            if store.replacements.isEmpty {
                Text("no replacement rules yet")
                    .font(.bbBody).foregroundColor(.bbDim)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(store.replacements) { r in
                HStack(spacing: 0) {
                    Text(r.wrong)
                        .font(.bbBody).foregroundColor(.bbRed)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: 220, alignment: .leading)
                    HStack(spacing: 6) {
                        Text("→").font(.bbBody).foregroundColor(.bbDim)
                        Text(r.right)
                            .font(.bbBody).foregroundColor(.bbGreen)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: {
                        pendingReplDelete = r
                        showReplAlert = true
                    }) {
                        Text("×")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.bbRed)
                            .frame(width: 40)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                Divider().background(Color.bbBorder)
            }
        }
    }

    private var addReplacementRow: some View {
        HStack(spacing: 8) {
            Text("ADD:").font(.bbSmall).foregroundColor(.bbDim)
            Text("WRONG").font(.bbSmall).foregroundColor(.bbDim)
            TextField("", text: $newWrong)
                .textFieldStyle(.plain)
                .font(.bbBody).foregroundColor(.bbRed)
                .padding(6)
                .background(Color(white: 0.06))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbBorder, lineWidth: 1))
                .frame(maxWidth: 200)
            Text("→").font(.bbBody).foregroundColor(.bbDim)
            Text("RIGHT").font(.bbSmall).foregroundColor(.bbDim)
            TextField("", text: $newRight)
                .textFieldStyle(.plain)
                .font(.bbBody).foregroundColor(.bbGreen)
                .padding(6)
                .background(Color(white: 0.06))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbBorder, lineWidth: 1))
                .frame(maxWidth: 200)
            Button(action: {
                if store.addReplacement(wrong: newWrong, right: newRight) {
                    newWrong = ""; newRight = ""
                }
            }) {
                Text("+ ADD")
                    .font(.bbHeader).foregroundColor(.bbAmber)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbAmber, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(14)
        .background(Color(white: 0.03))
    }
}
