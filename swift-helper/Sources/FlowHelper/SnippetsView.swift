// Snippets management tab.

import SwiftUI

struct SnippetsView: View {
    @ObservedObject var store = SnippetStore.shared
    @State private var newTrigger: String = ""
    @State private var newExpansion: String = ""
    @State private var pendingDelete: Snippet? = nil
    @State private var showDeleteAlert: Bool = false
    @State private var formError: String? = nil
    /// When set, the add form is editing this existing snippet instead of
    /// creating a new one. We delete the original on save if the trigger
    /// was renamed.
    @State private var editingOriginalTrigger: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider().background(Color.bbBorder)
            listHeader
            Divider().background(Color.bbBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.snippets.isEmpty {
                        Text("no snippets yet — add one below")
                            .font(.bbBody)
                            .foregroundColor(.bbDim)
                            .padding(20)
                    }
                    ForEach(store.snippets) { snip in
                        snippetRow(snip)
                        Divider().background(Color.bbBorder)
                    }
                }
            }
            Divider().background(Color.bbBorder)
            addForm
        }
        .background(Color.bbBlack)
        .alert("Delete snippet?",
               isPresented: $showDeleteAlert,
               presenting: pendingDelete) { snip in
            Button("Delete", role: .destructive) {
                _ = store.delete(trigger: snip.trigger)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { snip in
            Text("Trigger: \(snip.trigger)")
        }
    }

    private var headerRow: some View {
        HStack {
            Text("SNIPPETS")
                .font(.bbHeader).foregroundColor(.bbAmber)
            Text("(\(store.snippets.count))")
                .font(.bbSmall).foregroundColor(.bbDim)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.04))
    }

    private var listHeader: some View {
        HStack(spacing: 0) {
            Text("TRIGGER")
                .font(.bbSmall).foregroundColor(.bbDim)
                .frame(width: 220, alignment: .leading)
            Text("EXPANSION")
                .font(.bbSmall).foregroundColor(.bbDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("")
                .frame(width: 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.03))
    }

    private func snippetRow(_ snip: Snippet) -> some View {
        HStack(spacing: 0) {
            Text(snip.trigger)
                .font(.bbBody).foregroundColor(.bbCyan)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 220, alignment: .leading)
            Text(snip.expansion.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.bbBody).foregroundColor(.bbGreen)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: {
                editingOriginalTrigger = snip.trigger
                newTrigger = snip.trigger
                newExpansion = snip.expansion
                formError = nil
            }) {
                Text("✎")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.bbAmber)
                    .frame(width: 26)
            }
            .buttonStyle(.plain)
            Button(action: {
                pendingDelete = snip
                showDeleteAlert = true
            }) {
                Text("×")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.bbRed)
                    .frame(width: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(editingOriginalTrigger == nil ? "ADD NEW" : "EDIT SNIPPET")
                    .font(.bbHeader).foregroundColor(.bbAmber)
                if editingOriginalTrigger != nil {
                    Button(action: cancelEdit) {
                        Text("CANCEL")
                            .font(.bbSmall).foregroundColor(.bbDim)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.bbBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, 10)

            HStack(alignment: .top, spacing: 10) {
                Text("TRIGGER:")
                    .font(.bbSmall).foregroundColor(.bbDim)
                    .frame(width: 90, alignment: .leading)
                    .padding(.top, 6)
                TextField("", text: $newTrigger)
                    .textFieldStyle(.plain)
                    .font(.bbBody)
                    .foregroundColor(.bbCyan)
                    .padding(6)
                    .background(Color(white: 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbBorder, lineWidth: 1))
                    .onChange(of: newTrigger) { _, v in
                        if v.count > 60 { newTrigger = String(v.prefix(60)) }
                    }
            }

            HStack(alignment: .top, spacing: 10) {
                Text("EXPANSION:")
                    .font(.bbSmall).foregroundColor(.bbDim)
                    .frame(width: 90, alignment: .leading)
                    .padding(.top, 6)
                TextEditor(text: $newExpansion)
                    .font(.bbBody)
                    .foregroundColor(.bbGreen)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(white: 0.06))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbBorder, lineWidth: 1))
                    .onChange(of: newExpansion) { _, v in
                        if v.count > 4000 { newExpansion = String(v.prefix(4000)) }
                    }
            }

            HStack {
                if let err = formError {
                    Text(err).font(.bbSmall).foregroundColor(.bbRed)
                }
                Spacer()
                Button(action: addSnippet) {
                    Text(editingOriginalTrigger == nil ? "ADD SNIPPET" : "SAVE CHANGES")
                        .font(.bbHeader).foregroundColor(.bbAmber)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbAmber, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(white: 0.03))
    }

    private func addSnippet() {
        formError = nil
        let t = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || newExpansion.isEmpty {
            formError = "trigger and expansion are required"
            return
        }
        if store.add(trigger: t, expansion: newExpansion) {
            // If we were editing and the trigger was renamed, delete the old row.
            if let original = editingOriginalTrigger,
               original.lowercased() != t.lowercased() {
                _ = store.delete(trigger: original)
            }
            newTrigger = ""
            newExpansion = ""
            editingOriginalTrigger = nil
        } else {
            formError = store.lastError ?? "failed to save"
        }
    }

    private func cancelEdit() {
        editingOriginalTrigger = nil
        newTrigger = ""
        newExpansion = ""
        formError = nil
    }
}
