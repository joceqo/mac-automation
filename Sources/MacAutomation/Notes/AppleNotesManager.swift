import Foundation

/// Swift interface for Apple Notes operations.
/// Uses AppleScript for all write operations and reads.
/// All methods are async and run AppleScript on background queues.
public enum AppleNotesManager {

    // MARK: - Create

    /// Creates a new note in Apple Notes.
    /// - Parameters:
    ///   - title: The note title. If empty, Notes uses the first line of the body.
    ///   - body: The note content. Supports HTML — use `<h1>` for title, `<p>` for paragraphs.
    ///   - folderName: Optional folder to create the note in. If nil or not found, uses the default folder.
    /// - Returns: Success with confirmation message, or failure with error description.
    @discardableResult
    public static func createNote(
        title: String,
        body: String,
        folderName: String? = nil
    ) async -> AppleScriptRunner.Result {
        let escapedTitle = AppleScriptRunner.escapeForAppleScript(title)
        let escapedBody = escapeBodyForAppleScript(body)

        let folderClause: String
        if let folderName, !folderName.isEmpty {
            let escapedFolder = AppleScriptRunner.escapeForAppleScript(folderName)
            folderClause = """
                set targetFolder to missing value
                try
                    set targetFolder to folder "\(escapedFolder)"
                end try
                if targetFolder is not missing value then
                    tell targetFolder
                        make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
                    end tell
                else
                    make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
                end if
            """
        } else {
            folderClause = """
                make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
            """
        }

        let source = """
        tell application "Notes"
            \(folderClause)
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    // MARK: - Search

    /// Searches Apple Notes by title and body content (case-insensitive).
    /// Skips the "Recently Deleted" folder.
    /// - Parameter query: The text to search for in note titles and bodies.
    /// - Returns: Success with formatted search results, or failure with error description.
    public static func searchNotes(query: String) async -> AppleScriptRunner.Result {
        let escapedQuery = AppleScriptRunner.escapeForAppleScript(query)

        let source = """
        on toLowerCase(theText)
            return do shell script "echo " & quoted form of theText & " | tr '[:upper:]' '[:lower:]'"
        end toLowerCase

        tell application "Notes"
            set searchText to "\(escapedQuery)"
            set lowerSearch to my toLowerCase(searchText)
            set matchingResults to ""
            set matchCount to 0

            repeat with currentFolder in every folder
                set folderName to name of currentFolder
                if folderName is not "Recently Deleted" then
                    repeat with currentNote in every note of currentFolder
                        set noteTitle to name of currentNote
                        set titleMatch to (my toLowerCase(noteTitle)) contains lowerSearch

                        set bodyMatch to false
                        try
                            set noteBody to plaintext of currentNote
                            set bodyMatch to (my toLowerCase(noteBody)) contains lowerSearch
                        end try

                        if titleMatch or bodyMatch then
                            set matchCount to matchCount + 1
                            set noteId to id of currentNote
                            set matchingResults to matchingResults & "---" & return
                            set matchingResults to matchingResults & "title: " & noteTitle & return
                            set matchingResults to matchingResults & "folder: " & folderName & return
                            set matchingResults to matchingResults & "id: " & noteId & return

                            if bodyMatch then
                                try
                                    set snippetText to text 1 thru (min of 150 and (length of noteBody)) of noteBody
                                    if length of noteBody > 150 then set snippetText to snippetText & "..."
                                    set matchingResults to matchingResults & "snippet: " & snippetText & return
                                end try
                            end if

                            if matchCount ≥ 10 then exit repeat
                        end if
                    end repeat
                end if
                if matchCount ≥ 10 then exit repeat
            end repeat

            if matchCount is 0 then
                return "No notes found matching \\"" & searchText & "\\"."
            else
                return "Found " & matchCount & " note(s):" & return & matchingResults
            end if
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    // MARK: - Read

    /// Reads the plain text content of a note by its CoreData ID.
    /// - Parameter noteId: The CoreData ID (e.g. `x-coredata://...`). Obtained from search results.
    /// - Returns: Success with the note's plain text content, or failure with error description.
    public static func readNote(noteId: String) async -> AppleScriptRunner.Result {
        let escapedId = AppleScriptRunner.escapeForAppleScript(noteId)

        let source = """
        tell application "Notes"
            set theNote to note id "\(escapedId)"
            return plaintext of theNote
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    /// Reads the HTML body of a note by its CoreData ID.
    /// - Parameter noteId: The CoreData ID. Obtained from search results.
    /// - Returns: Success with the note's HTML body, or failure with error description.
    public static func readNoteHTML(noteId: String) async -> AppleScriptRunner.Result {
        let escapedId = AppleScriptRunner.escapeForAppleScript(noteId)

        let source = """
        tell application "Notes"
            set theNote to note id "\(escapedId)"
            return body of theNote
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    // MARK: - Append

    /// Appends text to an existing note, found by searching for a matching title.
    /// If multiple notes match, appends to the most recently modified one.
    /// - Parameters:
    ///   - searchTitle: Text to search for in note titles.
    ///   - content: The content to append (plain text or HTML).
    /// - Returns: Success with confirmation, or failure with error description.
    public static func appendToNote(
        searchTitle: String,
        content: String
    ) async -> AppleScriptRunner.Result {
        let escapedSearch = AppleScriptRunner.escapeForAppleScript(searchTitle)
        let escapedContent = escapeBodyForAppleScript(content)

        let source = """
        tell application "Notes"
            set targetNote to missing value

            repeat with currentFolder in every folder
                if name of currentFolder is not "Recently Deleted" then
                    repeat with currentNote in every note of currentFolder
                        if name of currentNote contains "\(escapedSearch)" then
                            set targetNote to currentNote
                            exit repeat
                        end if
                    end repeat
                end if
                if targetNote is not missing value then exit repeat
            end repeat

            if targetNote is missing value then
                return "No note found matching \\"" & "\(escapedSearch)" & "\\"."
            end if

            set existingBody to body of targetNote
            set body of targetNote to existingBody & "<br/><br/>" & "\(escapedContent)"
            return "Appended to \\"" & name of targetNote & "\\"."
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    /// Appends text to an existing note by its CoreData ID.
    /// - Parameters:
    ///   - noteId: The CoreData ID of the note.
    ///   - content: The content to append (plain text or HTML).
    /// - Returns: Success with confirmation, or failure with error description.
    public static func appendToNote(
        noteId: String,
        content: String
    ) async -> AppleScriptRunner.Result {
        let escapedId = AppleScriptRunner.escapeForAppleScript(noteId)
        let escapedContent = escapeBodyForAppleScript(content)

        let source = """
        tell application "Notes"
            set theNote to note id "\(escapedId)"
            set existingBody to body of theNote
            set body of theNote to existingBody & "<br/><br/>" & "\(escapedContent)"
            return "Appended to \\"" & name of theNote & "\\"."
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    // MARK: - Folders

    /// Lists all folder names in Apple Notes.
    /// - Returns: Success with newline-separated folder names, or failure with error description.
    public static func listFolders() async -> AppleScriptRunner.Result {
        let source = """
        tell application "Notes"
            set folderNames to ""
            repeat with currentFolder in every folder
                set folderNames to folderNames & name of currentFolder & return
            end repeat
            return folderNames
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    /// Creates a new folder in Apple Notes. No-op if the folder already exists.
    /// - Parameter name: The folder name to create.
    /// - Returns: Success with confirmation, or failure with error description.
    @discardableResult
    public static func createFolder(name: String) async -> AppleScriptRunner.Result {
        let escapedName = AppleScriptRunner.escapeForAppleScript(name)

        let source = """
        tell application "Notes"
            if exists folder "\(escapedName)" then
                return "Folder \\"" & "\(escapedName)" & "\\" already exists."
            end if
            make new folder with properties {name:"\(escapedName)"}
            return "Created folder \\"" & "\(escapedName)" & "\\"."
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    // MARK: - Open

    /// Opens a note in Apple Notes by its CoreData ID.
    /// - Parameter noteId: The CoreData ID of the note.
    /// - Returns: Success or failure.
    @discardableResult
    public static func openNote(noteId: String) async -> AppleScriptRunner.Result {
        let escapedId = AppleScriptRunner.escapeForAppleScript(noteId)

        let source = """
        tell application "Notes"
            set theNote to note id "\(escapedId)"
            show theNote
            activate
        end tell
        """

        return await AppleScriptRunner.run(source)
    }

    // MARK: - Private Helpers

    /// Escapes note body content for embedding in AppleScript.
    /// Handles backslashes, double quotes, and converts newlines to AppleScript `return` concatenation.
    private static func escapeBodyForAppleScript(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\" & return & \"")
    }
}
