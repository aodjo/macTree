import Foundation

/**
 * Minimal English / Korean localisation.
 *
 * The language is picked once from the user's first preferred language;
 * everything else falls back to English.
 */
enum L {
    /** Whether the UI shows Korean text; decided once at launch. */
    static let isKorean: Bool = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false

    /**
     * Picks the English or Korean variant of a string.
     *
     * @param {String} en - English text.
     * @param {String} ko - Korean text.
     * @returns {String} `ko` when the UI language is Korean, otherwise `en`.
     *
     * @example
     * L.t("Scan", "스캔") // "스캔" on a Korean system
     */
    @inline(__always) static func t(_ en: String, _ ko: String) -> String { isKorean ? ko : en }

    // MARK: General

    /** Application name, shown in the window title and menus. */
    static var appName: String { "MacTree" }
    /** File-type list label for files without an extension. */
    static var noExtension: String { t("(no extension)", "(확장자 없음)") }

    // MARK: Toolbar

    /** Toolbar button that starts a scan. */
    static var scan: String { t("Scan", "스캔") }
    /** Toolbar button and menu item that stop a running scan. */
    static var stop: String { t("Stop", "중지") }
    /** File menu item that rescans the current location. */
    static var rescan: String { t("Rescan", "다시 스캔") }
    /** Location pop-up entry that opens a folder picker. */
    static var chooseFolder: String { t("Choose Folder…", "폴더 선택…") }
    /** Toolbar label of the location pop-up. */
    static var location: String { t("Location", "위치") }
    /** Placeholder of the toolbar search field. */
    static var searchPlaceholder: String { t("Search files (e.g. *.mov, cache)", "파일 검색 (예: *.mov, cache)") }
    /** Toolbar label of the size-mode switch. */
    static var sizeModeLabel: String { t("Size", "크기 기준") }
    /** Size-mode segment for logical size. */
    static var sizeModeLogical: String { t("Size", "크기") }
    /** Size-mode segment for allocated size. */
    static var sizeModeAllocated: String { t("Allocated", "할당 크기") }

    // MARK: Tabs

    /** View switch segment for the folder tree. */
    static var treeView: String { t("Tree View", "트리 보기") }
    /** View switch segment for the flat file list. */
    static var fileView: String { t("File View", "파일 보기") }

    // MARK: Columns

    /** Column header: item name. */
    static var colName: String { t("Name", "이름") }
    /** Column header: share of the parent folder. */
    static var colPercent: String { t("% of Parent", "상위 대비 %") }
    /** Column header: logical size. */
    static var colSize: String { t("Size", "크기") }
    /** Column header: allocated size. */
    static var colAllocated: String { t("Allocated", "할당 크기") }
    /** Column header: files plus folders below an item. */
    static var colItems: String { t("Items", "항목") }
    /** Column header: file count. */
    static var colFiles: String { t("Files", "파일") }
    /** Column header: folder count. */
    static var colFolders: String { t("Folders", "폴더") }
    /** Column header: modification date. */
    static var colModified: String { t("Modified", "수정일") }
    /** Column header: containing folder in the File View and the unreadable-folders list. */
    static var colPath: String { t("Folder", "위치") }
    /** Column header of the file-type list. */
    static var colExtension: String { t("Extension", "확장자") }
    /** Column header: share of the whole scan in the file-type list. */
    static var colPercentTotal: String { t("%", "%") }

    // MARK: Status / summary

    /** Idle hint in the summary bar, status bar and empty treemap. */
    static var ready: String { t("Choose a volume or folder, then press Scan.", "볼륨이나 폴더를 선택한 뒤 스캔을 누르세요.") }
    /** Progress prefix while scanning. */
    static var scanning: String { t("Scanning", "스캔 중") }
    /** Summary bar: volume capacity. */
    static var total: String { t("Total", "전체") }
    /** Summary bar: space in use. */
    static var used: String { t("Used", "사용") }
    /** Summary bar: free space. */
    static var free: String { t("Free", "여유") }
    /** Summary bar: bytes found by the scan. */
    static var scanned: String { t("Scanned", "스캔됨") }
    /** Lower-case unit after a file count. */
    static var files: String { t("files", "파일") }
    /** Lower-case unit after a folder count. */
    static var folders: String { t("folders", "폴더") }
    /** Appended to the scan statistics when the scan was stopped early. */
    static var cancelledNote: String { t("(stopped — partial results)", "(중지됨 — 일부 결과)") }

    /**
     * Status bar text for the File View when no filter hides anything.
     *
     * @param {Int} n - Number of files listed.
     * @returns {String} e.g. "1,076,094 files".
     *
     * @example
     * status.rightLabel.stringValue = L.filesMatched(total)
     */
    static func filesMatched(_ n: Int) -> String { t("\(Fmt.count(n)) files", "파일 \(Fmt.count(n))개") }

    /**
     * Status bar text for the File View while a search filter is active.
     *
     * @param {Int} shown - Files that match the filter.
     * @param {Int} total - All files in the scan.
     * @returns {String} e.g. "4,771 of 1,076,094 files".
     *
     * @example
     * status.rightLabel.stringValue = L.filesShown(4_771, 1_076_094)
     */
    static func filesShown(_ shown: Int, _ total: Int) -> String {
        t("\(Fmt.count(shown)) of \(Fmt.count(total)) files", "파일 \(Fmt.count(total))개 중 \(Fmt.count(shown))개")
    }

    // MARK: Context menu

    /** Context menu: open with the default app. */
    static var open: String { t("Open", "열기") }
    /** Context and File menu: reveal in Finder. */
    static var revealInFinder: String { t("Show in Finder", "Finder에서 보기") }
    /** Context and File menu: Quick Look preview. */
    static var quickLook: String { t("Quick Look", "훑어보기") }
    /** Context and Edit menu: copy the path. */
    static var copyPath: String { t("Copy Path", "경로 복사") }
    /** Context and File menu, and the confirmation button: move to the Trash. */
    static var moveToTrash: String { t("Move to Trash", "휴지통으로 이동") }
    /** Context and File menu: rescan one folder. */
    static var rescanFolder: String { t("Rescan This Folder", "이 폴더 다시 스캔") }
    /** Context menu: show a folder on its own in the treemap. */
    static var zoomTreemap: String { t("Zoom Treemap Here", "트리맵 확대") }
    /** Treemap header button and View menu: zoom out. */
    static var zoomOut: String { t("Zoom Out", "축소") }
    /** Treemap header button and View menu: show the whole scan. */
    static var zoomReset: String { t("Show Whole Tree", "전체 보기") }
    /** Context menu on a file: list all files of its type. */
    static var showFilesOfType: String { t("Show Files of This Type", "이 형식의 파일 보기") }

    // MARK: Alerts

    /**
     * Title of the Move to Trash confirmation.
     *
     * @param {Int} n - Number of items to move.
     * @returns {String} Singular wording for one item, plural otherwise.
     *
     * @example
     * alert.messageText = L.trashConfirmTitle(targets.count)
     */
    static func trashConfirmTitle(_ n: Int) -> String {
        n == 1 ? t("Move this item to the Trash?", "이 항목을 휴지통으로 이동할까요?")
               : t("Move \(n) items to the Trash?", "\(n)개 항목을 휴지통으로 이동할까요?")
    }

    /**
     * Body of the Move to Trash confirmation.
     *
     * @param {String} size - Formatted total size of the items.
     * @returns {String} e.g. "12.3 GB will be moved to the Trash."
     *
     * @example
     * alert.informativeText = L.trashConfirmBody(Fmt.bytes(total))
     */
    static func trashConfirmBody(_ size: String) -> String {
        t("\(size) will be moved to the Trash.", "\(size)이(가) 휴지통으로 이동됩니다.")
    }

    /** Cancel button in alerts and sheets. */
    static var cancel: String { t("Cancel", "취소") }
    /** Title of the alert listing items that could not be trashed. */
    static var trashFailed: String { t("Could not move to Trash", "휴지통으로 이동하지 못했습니다") }

    // MARK: Permanent deletion

    /** Toolbar button, left of the search field, that deletes the marked items. */
    static var deletePermanently: String { t("Delete Permanently", "완전히 삭제") }
    /** Tooltip of the Delete Permanently button while nothing is marked. */
    static var deleteHint: String {
        t("Select items and press Delete to mark them, then click here to delete them permanently.",
          "항목을 선택하고 Delete 키로 삭제 대상을 표시한 뒤, 여기를 누르면 완전히 삭제합니다.")
    }
    /** Context menu: mark the selection for permanent deletion. */
    static var markForDeletion: String { t("Mark for Deletion", "삭제 대상으로 표시") }
    /** Context menu: remove the deletion mark. */
    static var unmarkForDeletion: String { t("Unmark for Deletion", "삭제 표시 해제") }
    /** Status bar text while marked items are being deleted. */
    static var deleting: String { t("Deleting…", "삭제 중…") }
    /** Title of the alert listing items that could not be deleted. */
    static var deleteFailed: String { t("Some items could not be deleted", "일부 항목을 삭제하지 못했습니다") }
    /** Note under the failed deletions: a folder may be half-deleted and its size stale. */
    static var deletePartialHint: String {
        t("A folder that failed may have been partly deleted; use Rescan This Folder to refresh its size.",
          "실패한 폴더는 일부만 삭제됐을 수 있습니다. ‘이 폴더 다시 스캔’으로 크기를 새로 고치세요.")
    }

    /**
     * Title of the Delete Permanently button while items are marked.
     *
     * @param {Int} n - Number of marked items.
     * @returns {String} e.g. "Delete Permanently (3)".
     *
     * @example
     * deleteButton.title = L.deletePermanentlyCount(3)
     */
    static func deletePermanentlyCount(_ n: Int) -> String {
        t("Delete Permanently (\(n))", "완전히 삭제 (\(n))")
    }

    /**
     * Summary of the marked items for the status bar and button tooltip.
     *
     * @param {Int} n - Number of marked items.
     * @param {String} size - Their formatted total size.
     * @returns {String} e.g. "3 items marked for deletion · 12.3 GB".
     *
     * @example
     * status.label.stringValue = L.markedSummary(3, "12.3 GB")
     */
    static func markedSummary(_ n: Int, _ size: String) -> String {
        t("\(n) items marked for deletion · \(size)", "삭제 대상 \(n)개 · \(size)")
    }

    /**
     * Title of the Delete Permanently confirmation.
     *
     * @param {Int} n - Number of items to delete.
     * @returns {String} Singular wording for one item, plural otherwise.
     *
     * @example
     * alert.messageText = L.deleteConfirmTitle(targets.count)
     */
    static func deleteConfirmTitle(_ n: Int) -> String {
        n == 1 ? t("Delete this item permanently?", "이 항목을 완전히 삭제할까요?")
               : t("Delete \(n) items permanently?", "\(n)개 항목을 완전히 삭제할까요?")
    }

    /**
     * Body of the Delete Permanently confirmation.
     *
     * @param {String} size - Formatted total size of the items.
     * @returns {String} A warning that the deletion is immediate and cannot be undone.
     *
     * @example
     * alert.informativeText = L.deleteConfirmBody(Fmt.bytes(total))
     */
    static func deleteConfirmBody(_ size: String) -> String {
        t("\(size) will be deleted immediately, without going to the Trash. This can't be undone.",
          "\(size)이(가) 휴지통을 거치지 않고 즉시 삭제됩니다. 되돌릴 수 없습니다.")
    }

    // MARK: Menus

    /** App menu: About. */
    static var menuAbout: String { t("About MacTree", "MacTree 정보") }
    /** App menu: Hide. */
    static var menuHide: String { t("Hide MacTree", "MacTree 가리기") }
    /** App menu: Hide Others. */
    static var menuHideOthers: String { t("Hide Others", "기타 가리기") }
    /** App menu: Show All. */
    static var menuShowAll: String { t("Show All", "모두 보기") }
    /** App menu: Quit. */
    static var menuQuit: String { t("Quit MacTree", "MacTree 종료") }
    /** File menu title. */
    static var menuFile: String { t("File", "파일") }
    /** Edit menu title. */
    static var menuEdit: String { t("Edit", "편집") }
    /** View menu title. */
    static var menuView: String { t("View", "보기") }
    /** Window menu title. */
    static var menuWindow: String { t("Window", "윈도우") }
    /** File menu: pick a folder and scan it. */
    static var menuScanFolder: String { t("Scan Folder…", "폴더 스캔…") }
    /** File menu: close the window. */
    static var menuClose: String { t("Close Window", "윈도우 닫기") }
    /** Edit menu: Copy. */
    static var menuCopy: String { t("Copy", "복사") }
    /** Edit menu: Select All. */
    static var menuSelectAll: String { t("Select All", "전체 선택") }
    /** Edit menu: focus the search field. */
    static var menuFind: String { t("Find", "찾기") }
    /** View menu: measure by logical size. */
    static var menuUseLogical: String { t("Measure by Size", "크기 기준으로 표시") }
    /** View menu: measure by allocated size. */
    static var menuUseAllocated: String { t("Measure by Allocated Size", "할당 크기 기준으로 표시") }
    /** Window menu: Minimize. */
    static var menuMinimize: String { t("Minimize", "최소화") }
    /** Window menu: Zoom. */
    static var menuZoom: String { t("Zoom", "확대/축소") }
    /** View menu: full screen. */
    static var menuFullScreen: String { t("Enter Full Screen", "전체 화면 시작") }
    /** View menu: show the Tree View. */
    static var menuShowTree: String { t("Tree View", "트리 보기") }
    /** View menu: show the File View. */
    static var menuShowFiles: String { t("File View", "파일 보기") }

    // MARK: Export

    /** File menu: export the scan as CSV. */
    static var exportCSV: String { t("Export CSV…", "CSV로 내보내기…") }
    /** Status bar prefix while exporting. */
    static var exporting: String { t("Exporting", "내보내는 중") }

    /**
     * Status bar text after a successful export.
     *
     * @param {Int} n - Number of rows written.
     * @param {String} path - Destination file path.
     * @returns {String} e.g. "Exported 1,231,942 rows to /Users/me/scan.csv".
     *
     * @example
     * status.label.stringValue = L.exported(rows, url.path)
     */
    static func exported(_ n: Int, _ path: String) -> String {
        t("Exported \(Fmt.count(n)) rows to \(path)", "\(Fmt.count(n))행을 내보냈습니다: \(path)")
    }

    /** Title of the export error alert. */
    static var exportFailed: String { t("Export failed", "내보내기에 실패했습니다") }

    // MARK: Full Disk Access

    /** Title of the Full Disk Access sheet. */
    static var fdaTitle: String { t("Allow Full Disk Access", "전체 디스크 접근 권한 허용") }
    /** Explanation at the top of the Full Disk Access sheet. */
    static var fdaBody: String {
        t("To measure the whole disk accurately, MacTree needs Full Disk Access. Without it, macOS hides folders such as Mail, Messages, Safari and other apps' data, and asks separately before MacTree can read Desktop, Documents and Downloads.",
          "디스크 전체를 정확하게 분석하려면 전체 디스크 접근 권한이 필요합니다. 권한이 없으면 macOS가 메일, 메시지, Safari, 다른 앱의 데이터 같은 폴더를 숨기고, 데스크탑·문서·다운로드 폴더는 읽기 전에 따로 허용을 묻습니다.")
    }
    /** Full Disk Access sheet, step 1. */
    static var fdaStep1: String { t("Click “Open System Settings”.", "‘시스템 설정 열기’를 누릅니다.") }
    /** Full Disk Access sheet, step 2. */
    static var fdaStep2: String {
        t("Turn on MacTree in the list. If it isn't listed, drag the icon on the right into the list (or click + and choose MacTree).",
          "목록에서 MacTree를 켭니다. 목록에 없으면 오른쪽 아이콘을 목록으로 끌어다 놓으세요(또는 + 버튼으로 MacTree 추가).")
    }
    /** Full Disk Access sheet, step 3. */
    static var fdaStep3: String { t("MacTree notices the change automatically.", "허용하면 MacTree가 자동으로 감지합니다.") }
    /** Status line while the sheet waits for the grant. */
    static var fdaWaiting: String { t("Waiting for Full Disk Access…", "권한 허용을 기다리는 중…") }
    /** Status line once the grant is usable. */
    static var fdaGranted: String { t("Full Disk Access is on.", "전체 디스크 접근 권한이 허용되었습니다.") }
    /** Hint above the relaunch link while still waiting. */
    static var fdaRelaunchHint: String { t("Turned it on but still waiting?", "허용했는데 계속 기다리는 중인가요?") }
    /** Status line when the grant exists but needs a relaunch to apply. */
    static var fdaGrantedNeedsRelaunch: String {
        t("Access is on. Relaunch MacTree to apply it.", "권한이 허용되었습니다. 적용하려면 MacTree를 다시 시작하세요.")
    }
    /** Button that relaunches the app. */
    static var fdaRelaunch: String { t("Relaunch MacTree", "MacTree 다시 시작") }
    /** Button that opens System Settings at Full Disk Access. */
    static var fdaOpenSettings: String { t("Open System Settings", "시스템 설정 열기") }
    /** Button that dismisses the sheet without access. */
    static var fdaLater: String { t("Not Now", "나중에") }
    /** Checkbox that stops the sheet from appearing at launch. */
    static var fdaDontAsk: String { t("Don't ask at launch", "실행할 때 묻지 않기") }
    /** Button that closes the sheet once access is granted. */
    static var fdaDone: String { t("Done", "완료") }
    /** Caption under the draggable app icon. */
    static var fdaDragHint: String { t("Drag into the list", "목록으로 드래그") }
    /** App menu item that reopens the Full Disk Access sheet. */
    static var menuFullDiskAccess: String { t("Full Disk Access…", "전체 디스크 접근 권한…") }

    /**
     * Summary bar warning when missing Full Disk Access hid folders.
     *
     * @param {Int} n - Number of unreadable folders.
     * @returns {String} A call to action that opens the permission sheet.
     *
     * @example
     * warningButton.title = L.deniedNeedsAccess(result.deniedCount)
     */
    static func deniedNeedsAccess(_ n: Int) -> String {
        t("\(Fmt.count(n)) folders could not be read — Allow Full Disk Access…",
          "권한이 없어 폴더 \(Fmt.count(n))개를 읽지 못함 — 권한 허용…")
    }

    /**
     * Summary bar note when only protected system folders were skipped.
     *
     * @param {Int} n - Number of unreadable folders.
     * @returns {String} A quiet note that opens the list of skipped folders.
     *
     * @example
     * warningButton.title = L.deniedSystem(result.deniedCount)
     */
    static func deniedSystem(_ n: Int) -> String {
        t("\(Fmt.count(n)) protected system folders skipped", "시스템 보호 폴더 \(Fmt.count(n))개 제외됨")
    }

    /**
     * Title of the unreadable-folders sheet.
     *
     * @param {Int} n - Number of unreadable folders.
     * @returns {String} e.g. "288 folders could not be read".
     *
     * @example
     * title.stringValue = L.deniedTitle(totalCount)
     */
    static func deniedTitle(_ n: Int) -> String {
        t("\(Fmt.count(n)) folders could not be read", "읽지 못한 폴더 \(Fmt.count(n))개")
    }

    /** Explanation in the unreadable-folders sheet. */
    static var deniedBody: String {
        t("These are system folders that macOS protects (System Integrity Protection) or that only the administrator account (root) can open. They are usually small and are left out of the totals.",
          "macOS가 보호하는(시스템 무결성 보호) 폴더이거나 관리자(root) 계정만 열 수 있는 시스템 폴더입니다. 대부분 용량이 작으며 합계에서 제외됩니다.")
    }
    /** Column header for why a folder was unreadable. */
    static var deniedReason: String { t("Reason", "이유") }
    /** Reason: privacy protection or System Integrity Protection. */
    static var reasonProtected: String { t("Protected by macOS", "macOS 보호") }
    /** Reason: Unix permissions allow only root. */
    static var reasonRootOnly: String { t("Administrator (root) only", "관리자(root) 전용") }
    /** Close button of the unreadable-folders sheet. */
    static var close: String { t("Close", "닫기") }

    // MARK: Treemap

    /** Mouse hint on the right of the treemap header. */
    static var treemapHint: String {
        t("Click: select · Delete: mark for deletion · Scroll: zoom · Drag: pan · Double-click: open folder · Right-click: menu",
          "클릭: 선택 · Delete: 삭제 표시 · 휠: 확대/축소 · 드래그: 이동 · 더블클릭: 폴더 열기 · 우클릭: 메뉴")
    }
}
