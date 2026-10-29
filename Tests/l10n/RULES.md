# 本地化转换规则（来自 l10n-inventory 工作流的合成方案，2026-10-24）

## 总体方案

GOAL. Add en, de and zh-Hant to GPXPointViewer using String Catalogs. The source language is zh-Hans and the keys are the existing Chinese literals. The zh-Hans UI must look byte-identical after conversion, apart from the explicitly listed number/date formatter changes.

PRE-FLIGHT (integrator, before any edit)
(a) Back up the working tree. The repo has only 2 commits and a large uncommitted diff, so ask the user for a checkpoint commit; otherwise `rsync -a --exclude .git` the tree into the scratchpad.
(b) Capture baselines with the current app, launched pinned to zh-Hans:
- hook `state` JSON for the fill/batch/review scenarios;
- the uitest suite results;
- sampletest/garmintest JSONL output.
(c) Line numbers drift. Other sessions are editing these files: TrackStore moved about +51 lines during the inventory, and ContentView's settings section is now at ~1511. Every agent locates sites by snippet, never by line.
(d) Two files are missing from the inventory. ExportSheet.swift (app target) has about 16 unique keys and `enum ExportMode: String { 全部/年/月/日/自定义 }`, displayed via Text(m.rawValue) at ~126 and ~366. StressTest.swift has one: track name "压力测试 · \(n.formatted()) 点".

WAVE 0: FOUNDATION (one agent, serial, then a zh-Hans regression gate)
0.1 project.pbxproj (hand-written; sequential 24-hex ids AA…/BB…; take the next unused ids after grepping):
- PBXProject: developmentRegion = "zh-Hans"; knownRegions = (Base, "zh-Hans", en, de, "zh-Hant").
- New PBXFileReferences (lastKnownFileType = text.json.xcstrings): GPXPointViewer/Localizable.xcstrings, GPXPointViewer/Cities.xcstrings, GPXPointViewer/InfoPlist.xcstrings, GPXQuickLook/Localizable.xcstrings, GPXQuickLook/InfoPlist.xcstrings, GPXThumbnail/InfoPlist.xcstrings.
- New sourcecode.swift reference: GPXPointViewer/L10nSupport.swift.
- Add each to its group: CC…02 GPXPointViewer, CC…04 GPXQuickLook, CC…05 GPXThumbnail.
- PBXBuildFiles: app Resources DD…03 gets Localizable, Cities and InfoPlist; GPXQuickLook Resources DD…06 (empty today) gets Localizable and InfoPlist; GPXThumbnail Resources DD…0A gets InfoPlist; L10nSupport.swift goes in app Sources DD…01 only.
- Build settings already present, verify and do not duplicate: LOCALIZATION_PREFERS_STRING_CATALOGS = YES at project level; SWIFT_EMIT_LOC_STRINGS = YES on all six target configs; GENERATE_INFOPLIST_FILE = YES; MACOSX_DEPLOYMENT_TARGET 14.0.
- Validate with `plutil -lint`, `xcodebuild -list`, and a duplicate-id grep. Do not touch xcuserdata.

0.2 Catalog files:
- Every Localizable/Cities catalog starts as `{"sourceLanguage" : "zh-Hans", "strings" : {}, "version" : "1.0"}`.
- Each InfoPlist.xcstrings gets key CFBundleDisplayName with zh-Hans/en/de/zh-Hant values:
  - app: GPX 点位查看器 / GPX Point Viewer / GPX-Punktbetrachter / GPX 點位檢視器
  - GPXQuickLook: GPX 预览 / GPX Preview / GPX-Vorschau / GPX 預覽
  - GPXThumbnail: GPX 缩略图 / GPX Thumbnail / GPX-Miniatur / GPX 縮圖
- Every main-window title translation must contain "GPX" and must equal the CFBundleDisplayName value.

0.3 L10nSupport.swift (Foundation only, so the CLI harnesses can compile it):
- `enum Fmt` with `static let f0/f1/f2/f3/f6/f8 = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(k))`.
- `static var listSeparator: String { String(localized: "list.separator", defaultValue: "、") }`.

0.4 GPXPointViewerApp.swift (app only):
- `enum SceneID { static let diff = "diff", batchFill = "batchFill", changeReview = "changeReview" }`, used in Window(id:) and openWindow(id:).
- `extension NSApplication { func window(scene: String) -> NSWindow? }`: match identifier?.rawValue == id or hasPrefix(id + "-"); fall back to `title == String(localized: "批量补点")`. Verify the real identifier string with the hook `windows` command, which must print identifiers.
- `enum AppLanguage` (see the language-override section).

0.5 Cross-file type changes (see enumsToIntroduce), in this order:
1. RouteMethod: RoadNetwork, TrackStore (deleteOnly at the 删点 draft, setBatchIncludeMethod), BatchFillWindow (filters ~392-409, method display ~59/~430), UITestHook JSON (`method?.rawValue ?? ""`).
2. RoadNetwork.finish(_:warnings:lengthWarnings:notes:), which drops lengthWarnings when trimExcursion fired; delete the hasPrefix filter.
3. Display titles on ColorMode, BaseMapStyle, GlobeStyle, AppearanceMode (TrackData), DisplayMode (TrackStore) and ExportMode (ExportSheet), plus replacing every Text(x.rawValue). RawValues stay frozen.
4. Window lookup in TrackStore.dockBatchWindow and PointMapView.uncoveredInsets (~1502) through NSApp.window(scene:).
5. UITestHook:
   - confirm/cleanreplays return "…: button not found (lang=…)" instead of the crashing direct fallback;
   - movewin/shotwin/shotviewwin also match identifier;
   - the 超时 injection uses NetworkHealth.describe(URLError(.timedOut)).

0.6 GATE: build Debug (one xcodebuild at a time, -derivedDataPath in the scratchpad), then run the full uitest suite pinned with `open -n --env GPXPV_UITEST_DIR=<dir> <testcopy.app> --args -AppleLanguages '(zh-Hans)'`. Results must match the baseline; the hook must report "confirm (click …)".

WAVE 1: PER-FILE CONVERSION (parallel; each agent owns its files; agents do not build)
- A: ContentView.swift
- B: TrackStore.swift
- C: BatchFillWindow.swift
- D: ChangeReviewWindow.swift, ChangeLog.swift, DiffWindow.swift, BatchFill.swift
- E: RoadNetwork.swift
- F: GapFill.swift
- G: TrackData.swift, GPXParser.swift, GPXWriter.swift (errorDescription only), ExportSheet.swift, StressTest.swift
- H: PointMapView.swift, VideoExport.swift, PixelGlobe.swift (127 cities into the Cities table)
- I: GPXQuickLook/PreviewViewController.swift

Each agent applies the mechanical rules, then returns a list of (snippet → construct → action) plus any site it could not convert. The integrator builds after the wave. Compile errors go back to the owning agent. Then the zh-Hans gate (0.6) and the harness byte-diff run again.

WAVE 2: LANGUAGE OVERRIDE (one agent, ContentView settingsSheet ~1511, after A finishes)
- Add a row after 外观: Text("语言") at 60pt plus a menu-style Picker over AppLanguage.allCases.
- Labels: system shows localized "跟随系统" (key shared with AppearanceMode); the others use autonyms via Text(verbatim:): 简体中文, English, Deutsch, 繁體中文.
- Selection is initialized from AppLanguage.stored and written with AppLanguage.apply on change:
  - stored = UserDefaults.standard.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String], first element, prefix-matched; nil means system;
  - apply = set([code], forKey: "AppleLanguages") or removeObject(forKey:).
- When the selection differs from the snapshot taken at launch, show caption "重启 app 后生效" and Button("立即重启"):
  - if the session has unexported changes (change log non-empty, fill mode active or batch running), first confirm with alert "重启会丢失本次会话的修改记录，仍要重启？" and buttons 重启/取消;
  - relaunch via NSWorkspace.OpenConfiguration with createsNewApplicationInstance = true, openApplication(at: Bundle.main.bundleURL), then NSApp.terminate on completion.
- Optional caption: the same setting exists under 系统设置 › 通用 › 语言与地区 › 应用程序.
- The argument-domain -AppleLanguages used by the tests overrides the stored choice, so tests stay in Chinese.

WAVE 3: EXTRACT, TRANSLATE, ASSEMBLE
3.1 Authoritative keys:
- Run `xcodebuild -exportLocalizations -project GPXPointViewer.xcodeproj -localizationPath $S/l10n/export -exportLanguage en -exportLanguage de -exportLanguage zh-Hant`.
- Parse each `$S/l10n/export/<lang>.xcloc/Localized Contents/<lang>.xliff` with python3 -I and xml.etree: per <file original="…/X.xcstrings">, read trans-unit@id (the key), <source> and <note> (the comment).
- Cross-check against the union of keys in the build's `*.stringsdata` JSON files (find $DD -name '*.stringsdata'; tables → [{key, comment}]). The two sets must match per table.
- List non-Chinese keys (A, B, ×, %lld m, …) for verbatim fixing (go back to wave 1) or shouldTranslate=false.

3.2 Translation table $S/l10n/translations.jsonl:
- One row per (table, key): comment, en, de, zh-Hant, optional plural {lang: {one, other}} or substitutions, optional noTranslate.
- Translator agents get chunks of about 80 keys with the glossary, punctuation rules and comments, plus the plural policy list (rule 17).
- Each chunk is validated by the parity script before merging.

3.3 Assembler (python3 -I) writes each catalog:
- Shape: {"sourceLanguage":"zh-Hans","strings":{key:{"comment":c,"localizations":{"en":{"stringUnit":{"state":"translated","value":v}},"de":…,"zh-Hant":…}}},"version":"1.0"}.
- Semantic keys (defaultValue) also get "zh-Hans": {"stringUnit": {"state": "translated", "value": <defaultValue>}}.
- Single-count plurals: "en": {"variations": {"plural": {"one": {"stringUnit": …}, "other": {"stringUnit": …}}}}, and the same for de.
- Multi-count plurals: "en": {"stringUnit": {"value": "Insert %#@ins@, replace %#@rem@"}, "substitutions": {"ins": {"argNum": 1, "formatSpecifier": "lld", "variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": "%arg point"}}, "other": …}}}, …}}.
- No-translate keys: {"shouldTranslate": false}.
- Merge into any existing entries, keeping Xcode's extractionState.
- Output: json.dump(ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) to keep Xcode's formatting.
- Optional round-trip check: export again and confirm every trans-unit is state="translated".

WAVE 4: VERIFICATION
V1. zh-Hans regression: the full uitest suite, pinned, with network tests one at a time (FOSSGIS discipline). State JSON (method rawValues, notes, errors) must equal the baseline.
V2. CLI harnesses (sampletest, garmintest) rebuilt with L10nSupport.swift added; JSONL byte-identical to the baseline.
V3. Static audits:
- the scanner ($S/strlits.py) lists the remaining Chinese literals that are not in String(localized:), LocalizedStringResource, defaultValue or SwiftUI-literal positions; only whitelisted ones may remain (UITestHook, debug/assert/print, persisted/identifier rawValues, RouteMethod rawValues, the 一生足迹 creator token, GPX metadata decisions);
- `grep -n 'Text([^"]*rawValue)'` returns 0;
- `grep -n '\.title == "'` returns 0;
- `grep -n 'String(format: "[^"]*[一-龥]'` returns 0;
- `grep -n NSLocalizedString` returns 0.
V4. Catalog script:
- key coverage equals the extracted set in both directions;
- every translatable key has translated en/de/zh-Hant;
- placeholder multiset parity, with positional forms normalized and %% counted;
- en/de contain no CJK and no full-width punctuation;
- zh-Hant is unchanged by the ICU "Hans-Hant" transform (a small swift script using applyingTransform);
- every 「X」 cross-reference uses the glossary translation of X.
V5. Build Debug and Release: no xcstrings/format-specifier warnings. The .app has Contents/Resources/{zh-Hans,en,de,zh-Hant}.lproj/{Localizable.strings,Localizable.stringsdict,Cities.strings,InfoPlist.strings}, and the appex bundles have their own lproj folders (check with plutil -p).
V6. Runtime under `--args -AppleLanguages '(en)'`, then '(de)', then '(zh-Hant)'. Walk:
- main panel sections, settings sheet, fill mode, gap list, fill and replay alerts;
- batch, change-log and diff windows, export sheet;
- image/video save panels, network banner, globe city labels.
Check German truncation (44/60pt labels, 110–150pt segmented pickers, 290pt panels, batch table columns). If the screen is locked, shotviewwin may not render text, so ask the user to eyeball. Quick Look: confirm the appex localizations and run qlmanage -p on a sample.
V7. Language override: choosing English writes AppleLanguages into ~/Library/Containers/de.wayne.GPXPointViewer/Data/Library/Preferences/de.wayne.GPXPointViewer.plist; 立即重启 relaunches in English; 跟随系统 removes the key. Pinned test launches stay Chinese.
V8. A previously saved appearanceMode "夜间" is still restored.
V9. Install with the documented procedure only after the user approves, and delete the DerivedData Release copy.

KEY ESTIMATE
- The scanner found 1014 Chinese outer literals with 887 unique (127 of them cities). There are about 40 more nested literals, splits for homonyms and conditional variants, about 20 enum titles and about 12 non-Chinese auto keys. Dedupe of identical keys and fragment merges remove about 80.
- Totals:
  - app Localizable ≈ 720 ± 60;
  - Cities 127;
  - GPXQuickLook ≈ 8 (PreviewViewController plus the GPXParser errors compiled into it);
  - InfoPlist 3;
  - ≈ 860 keys in all.
- That is about 2,600 translated strings, plus about 120 plural-bearing keys (en/de one/other).

## 规则

### R1
SCOPE: convert only text that reaches the screen. Never touch:
- comments;
- print/NSLog/UITestHook.log/debug?()/assert/precondition/fatalError strings;
- any UITestHook.swift literal;
- file-format tokens (CSV headers, GPX/XML templates, creator sniff tokens incl. "一生足迹");
- UserDefaults keys and persisted values; scene ids (diff/batchFill/changeReview); the "root" coordinate space; cache keys; regexes; URLs, queries and HTTP headers; SF Symbol and resource names; file extensions;
- hook/GapInputDump JSON fields and values;
- any String(format:) whose result is not shown in the UI (GPXWriter, GapFillExport, cache keys, URL coordinates).

### R2
LOCATE BY SNIPPET: inventory line numbers are stale and the files are being edited concurrently. Re-read the file right before each Edit and match on the literal text. If a snippet is gone, report it instead of guessing.

### R3
KEY = CURRENT zh-Hans TEXT: while converting, do not reword, re-punctuate or fix Chinese source strings (e.g. leave "退出(不删)" as is); zh-Hans must render identically. Only two key changes are allowed: merging fragments into whole sentences (FRAGMENTS) and semantic keys for homonyms (HOMONYMS).

### R4
SWIFTUI LITERALS STAY: a literal (with or without \( ) interpolation) passed straight to a LocalizedStringKey parameter is already localized: Text, Button, Toggle, Label(_:systemImage:), Picker, Menu, Section, TableColumn, ColorPicker, Link, .help, .alert/.confirmationDialog titles, .navigationTitle, Window/WindowGroup. Do NOT wrap these in String(localized:). Interpolation maps Int→%lld, Double→%lf, String or .formatted()→%@; an explicit specifier: is used verbatim.

### R5
TERNARY / ?? TRAP: if any branch of a ternary, or the right side of ??, is a non-literal (a String variable, model property or concatenation), the whole argument becomes String and is NOT localized.
- Text: rewrite as if/else with one Text("…") per branch, or `cond ? Text("a") : Text(verbatim: s)`.
- Modifiers/Button titles: use `let k: LocalizedStringKey = …` when all branches are literals, otherwise String(localized:) on each literal branch.
- All-literal ternaries may stay, but must appear in the extracted key list.

### R6
STRING CONTEXT → String(localized:): wrap every Chinese literal that ends up in a String as `String(localized: "<exact literal>", comment: "<where shown; meaning of each placeholder>")`, with interpolations left inline. This covers:
- var/let/@Published/struct field assignment, enum payloads, return values, String parameters and array elements;
- Error payloads and errorDescription;
- NSOpenPanel/NSSavePanel .message/.nameFieldStringValue and CATextLayer.string.
Never use NSLocalizedString or String(localized: someVariable). Strings created off the main actor are fine (thread-safe), and freezing them at creation time is acceptable because a language change needs a relaunch.

### R7
HOIST FIRST: before wrapping, move into `let` locals any interpolated expression that contains a literal, closure, reduce/map, nested ternary or formatted-string call. Inside String(localized:) the interpolation must be a simple identifier or property, and every literal it used gets its own String(localized:), e.g. `let kind = item.autoKind?.label ?? String(localized: "不确定")`.

### R8
LABEL HELPERS: change the label parameter of private helpers that only receive literals to LocalizedStringKey, leaving call sites unchanged: fogStatRow, infoRow, statRow, anchorLabel (pass a key or isA), placeholder, legendDot, DiffWindow.label(text:). If a helper also receives runtime Strings, add an overload that renders Text(verbatim:).

### R9
FRAGMENTS: never localize a fragment that is later glued with + or interpolation. Turn "甲" + x + "乙" into String(localized: "甲\(x)乙"). For optional clauses, either pick between complete-sentence keys (if/else) or collect a [String] of independently complete clauses and join them in code. Keys must not start or end with whitespace, \n, " · ", "；", "，" or "、". \n inside a single paragraph is fine. Fragments starting with \n\n become separate paragraphs joined with "\n\n" in code.

### R10
SEPARATORS: " · ", "  ·  ", " → ", "\n" are language-neutral code literals. The enumeration separator "、" used in joined(separator:) becomes Fmt.listSeparator (key list.separator, defaultValue "、", en/de ", "). Do not use .formatted(.list): it changes the zh-Hans output.

### R11
String(format:) WITH CHINESE: rewrite as String(localized:) interpolation.
- Int arguments → \(n), giving %lld (plural-capable); never leave %d in a localized key.
- Double arguments → \(x, format: Fmt.f0/f1/f2) (locale decimal separator, grouping never), which shows as %@.
- %% in the old format becomes a single % (the compiler escapes it in the key).
- A %@ argument that is itself Chinese is localized at its source or expanded into whole-sentence variants (e.g. 开/关, 达到/不到 50%).
- Fallback only when interpolation is impossible: String(format: String(localized: "<literal>"), locale: .current, args…), with every %d changed to %lld.

### R12
SwiftUI Text(String(format: "中文…")) → Text("…\(x, specifier: "%.0f")…") (SwiftUI formats with the environment locale), with each branch-specific Chinese fragment expanded into a whole key. Example: 原始点距 ≈%.0f m / %.0f s（手动） and …（自动跟随） become two keys.

### R13
HOMONYMS: when identical Chinese must translate differently, keep zh-Hans unchanged with a semantic ASCII key plus defaultValue: String(localized: "exportMode.year", defaultValue: "年", comment:) or Text(LocalizedStringResource("count.archives", defaultValue: "\(n) 个")).
- Known cases: the ExportMode titles (all five: exportMode.*) vs the 年/月/日 date-row suffixes; "%lld 个" for fog archives vs files in ContentView; the 左/右 compare badges.
- Same-meaning duplicates share one key: 取消, 时间, 全部, 删点 (toggle and method label), 跟随系统 (appearance and language).

### R14
IDENTIFIERS: never wrap rawValues, dictionary keys, switch or == operands, persisted values or hook JSON values in String(localized:). Display goes through a `title`/`label` computed property: a switch with literal keys returning LocalizedStringResource, or String(localized:) for String contexts. Never build a key dynamically from rawValue. Replace every Text(x.rawValue) with Text(x.title). Turn comparisons of displayed text into enum-case comparisons.

### R15
WINDOWS: never compare NSWindow.title with a literal; use NSApp.window(scene: SceneID.batchFill). Window/WindowGroup titles stay plain literals (auto-localized). The main-window title must contain "GPX" in every language and match CFBundleDisplayName.

### R16
VERBATIM: literals with nothing to translate that pass through LocalizedStringKey become Text(verbatim:): "A", "B", "×", "×\(n)", "·", "\(n)m", "\(n) m", "\(n)s", "N", "—", pure numbers.
- Exception: the date range "\(a) ~ \(b)" stays a key; en/de translate it as "%1$@ – %2$@".
- Empty labels get a real key with .labelsHidden() (Toggle("显示此存档"), Picker("断档类型"), ColorPicker("点颜色")).
- Hidden shortcut buttons Button(""){…} become Button {…} label: { EmptyView() }.

### R17
COUNTS / PLURALS:
- Small, noun-bearing counts interpolate the Int (%lld) and get en/de one/other variants: 处, 段, 条, 步, 次, 批, 秒, 核, 个文件, 个存档, 个回放点, 个乱跳点, insert/remove counts, skipped files. zh-Hans/zh-Hant get no variants.
- Large counts already shown with .formatted() stay %@ to keep grouping (points 点 and cells 格, e.g. in "已选 %@" and "将导出 %@ 个点"). en/de phrase those without agreement ("Points: %@", "%@ cells").
- Multi-count keys use catalog substitutions (%#@name@, argNum, formatSpecifier "lld").

### R18
NUMBERS & DATES ON SCREEN:
- Unit labels such as String(format: "%.1f km", v) → "\(v.formatted(Fmt.f1)) km"; percentages → v.formatted(.percent.precision(.fractionLength(0))).
- The scale bar keeps metric units: never use Measurement's default usage, which converts to miles.
- "yyyy年M月d日" (PlaybackBarView, VideoExport.dayFmt) → setLocalizedDateFormatFromTemplate("yMMMd"), which gives identical zh-Hans output.
- Neutral numeric patterns (yy-MM-dd HH:mm, yyyy-MM-dd, HH:mm:ss, MM-dd HH:mm, yyyy-MM-dd HH:mm:ss, HH:mm) keep their pattern and get locale en_US_POSIX plus a gregorian calendar. No catalog keys for any of these.

### R19
STATIC TEXTS & TABLES:
- static let UI strings (e.g. LocalSampling.helpText) become `static var … { String(localized:) }`.
- PixelGlobe GlobeCity.name becomes LocalizedStringResource("北京", table: "Cities", comment: "City label: Beijing (39.90,116.41)"), resolved with String(localized:) at both the CATextLayer string and the width measurement.
- zh-Hant city names use Taiwan exonyms (雪梨, 杜拜, 伯斯, 布里斯本, 利雅德, 臺北); de uses German exonyms (Peking, München, Wien, Prag, Mailand, Kairo, Neu-Delhi, Mexiko-Stadt…).

### R20
APPKIT & FILES:
- Panel .message → String(localized:). Delete the panel.prompt = "打开" override so the system localizes the button.
- Default filename fragments "补点增量" and "时光机" become String(localized:) with comment "filename fragment: no / or :" (en fills / Timelapse, de Lückenfüllung / Zeitraffer).
- Keep the base name, _GPVexported, merge_N and the w.mp4 suffix unchanged.
- "未命名轨迹" and the GPX <name> "%@ 补点增量" follow the UI language; this is accepted.

### R21
ENGINE-FILE CONSTRAINT: GapFill, RoadNetwork, BatchFill, TrackData, GPXParser and GPXWriter are compiled by the CLI harnesses (and GPXParser by both extensions). They may use only Foundation and L10nSupport.swift; add L10nSupport.swift to the harness swiftc commands. Display statuses that share OSRMOutcome.status with the ASCII tokens NoRoute/NoSegment are localized; the tokens stay as they are.

### R22
TRANSLATOR COMMENTS: give every String(localized:) a comment:. Add Text(_:tableName:bundle:comment:) comments only to ambiguous SwiftUI keys:
- single characters;
- keys containing a literal %;
- keys quoting another control in 「」;
- keys with 3+ placeholders (list each placeholder's meaning in order).

### R23
EXTENSIONS:
- GPXQuickLook uses String(localized:) resolved against the appex bundle, with its own Localizable.xcstrings.
- The duration "\(h) 小时 \(m) 分" becomes Duration.seconds(span).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)).
- Pass the "抽样显示" flag into summaryLine and join with the existing "  ·  ".
- Date range: DateIntervalFormatter or the "%@ ~ %@" key; the fixed yyyy-MM-dd gets POSIX/gregorian.
- GPXThumbnail needs only InfoPlist.xcstrings.

### R24
TRANSLATION STYLE:
- zh-Hant uses Taiwan vocabulary, not character conversion: 檔案, 影片, 預設, 網路, 伺服器, 設定, 匯出/匯入, 快取, 選單, 訊號, 滑鼠, 程式, 衛星. It keeps full-width punctuation and 「」.
- en: ASCII punctuation, “ ” quotes, Title Case for buttons and menu items, sentence case for help text.
- de: „ “ quotes; formal Sie or infinitive imperatives; buttons in infinitive (Exportieren…).
- Keep … on controls that open dialogs.
- Never translate units (m, km, km/h, s, min), A/B, OSRM, Valhalla, Overpass, OpenStreetMap, "© OpenStreetMap contributors", FOSSGIS, gpx.studio, Metal, GPX, CSV, .fwdb, host names or user data.
- 世界迷雾 = Fog of World (en/de) / 世界迷霧. 一生足迹 in prose = Step of My World.
- A literal % in argument-free keys stays single.

### R25
GLOSSARY (fixed before translating; 「X」 cross-references must reuse these exactly), en / de / zh-Hant:
- 补点 = Gap Fill / Lücken füllen / 補點
- 断档 = gap / Lücke / 斷檔
- 锚点 = anchor / Anker / 錨點
- 替换 = Replace / Ersetzen / 替換
- 保留 = Keep / Behalten / 保留
- 插入 = Insert / Einfügen / 插入
- 落地 = Apply / Übernehmen / 落地
- 撤销落地 = Undo Apply / Übernahme rückgängig / 撤銷落地
- 修改记录 = Change Log / Änderungsprotokoll / 修改記錄
- 找不同 = Find Differences / Unterschiede finden / 找不同
- 批量补点 = Batch Gap Fill / Stapel-Lückenfüllung / 批量補點
- 一键补全部… = Fill All… / Alle füllen… / 一鍵補全部…
- 路网草稿 = Road Draft / Straßenentwurf / 路網草稿
- 回放点 = replay points / Wiederholungspunkte / 回放點
- 回放点清理 = Replay Cleanup / Bereinigung der Wiederholungspunkte / 回放點清理
- 乱跳 = jitter / Sprünge / 亂跳
- 大跳 = big jumps / große Sprünge / 大跳
- 倒退 = reversals / Rückschritte / 倒退
- 采样稀疏 = sparse sampling / spärliche Abtastung / 採樣稀疏
- 信号中断 = signal loss / Signalverlust / 訊號中斷
- 过时时钟 = stale clock / veraltete Uhrzeit / 過時時鐘
- 疑似铁路 = Likely Rail / Vermutlich Bahn / 疑似鐵路
- 公路 = Road / Straße / 公路
- 铁路 = Rail / Bahn / 鐵路
- 跳过 = Skip / Überspringen / 跳過
- 不补 = Don't Fill / Nicht füllen / 不補
- RouteMethod 匹配 = Match / Abgleich / 匹配
- RouteMethod 上下文 = Context / Kontext / 上下文
- RouteMethod 远上下文 = Far Context / Weiter Kontext / 遠上下文
- RouteMethod 约束 = Constrained / Eingeschränkt / 約束
- RouteMethod 直接 = Direct / Direkt / 直接
- RouteMethod 铁路 = Rail / Bahn / 鐵路
- RouteMethod 删点 = Delete Only / Nur löschen / 刪點
- 时间筛选 = Time Filter / Zeitfilter / 時間篩選
- 迷雾存档 = fog archive / Fog-Archiv / 迷霧存檔
- 时光机 = Timelapse / Zeitraffer / 時光機
- 详细 = Details / Details / 詳細
- 自动 = Auto / Automatisch / 自動

### R26
KEYS COME FROM EXTRACTION, NEVER BY HAND. The compiler escapes % to %% in interpolated keys and chooses %lld/%lf/%@. Use the xcodebuild -exportLocalizations XLIFF ids, cross-checked against the build's *.stringsdata.

### R27
PLACEHOLDER PARITY: every translation keeps the source's placeholder multiset (count and types; lld stays lld). Use positional forms (%1$@, %2$lld) whenever the order changes, and keep %% as %%. A type mismatch can crash at runtime, so a script enforces this and Xcode warnings must be zero.

### R28
LANGUAGE OVERRIDE: read AppleLanguages only from UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!), not from array(forKey:), which also returns the global value. Write with set([code]); follow-system calls removeObject(forKey:). The change applies on relaunch. Show language names as autonyms via Text(verbatim:).

### R29
UITESTHOOK COMPATIBILITY:
- Hook literals stay Chinese.
- Every self-test launch adds `--args -AppleLanguages '(zh-Hans)'` to `open -n --env GPXPV_UITEST_DIR=…`; the argument domain beats any stored override.
- confirm/cleanreplays never fall back to the direct (crashing) store call.
- Window commands also match the scene identifier.
- The method JSON emits RouteMethod.rawValue.
- uitest scripts that assert Chinese text (网络不好, 上下文/匹配/行进方向/成因/采样/半径 2x, 删点, 失败, window titles 批量补点/修改记录) are valid only under the pinned zh-Hans language.

### R30
PROCESS:
- Wave 0 (shared types, project, catalogs) is one serial agent.
- Wave-1 agents edit only their assigned files and never build.
- The integrator runs one xcodebuild at a time with a private -derivedDataPath and routes compile errors to the owning agent.
- Agent plans, results and failures are logged in saved-agent-results/AGENT_LOG.md.
- Network tests run one client at a time.
- Install to /Applications only after the user approves, per the install procedure.


## 要引入的枚举 / 类型

- RouteMethod (RoadNetwork.swift): `enum RouteMethod: String, Codable { case match = "匹配", context = "上下文", farContext = "远上下文", constrained = "约束", direct = "直接", rail = "铁路", deleteOnly = "删点" }`.
- rawValues are frozen because hook JSON and uitest scripts depend on them.
- `var label: String` is a switch of String(localized:) using the glossary terms.
- `var tieRank: Int` replaces the `order` dictionary (match 0, context 1, constrained 2, direct 3, else 9).
- RouteDraft.method changes from String = "" to RouteMethod?.
- The candidate tuple `name: String` becomes `method: RouteMethod`, and tryContext/fetchDirect take RouteMethod.
- Notes and errors that mention a candidate insert method.label.
- TrackStore's delete-only draft uses .deleteOnly.
- setBatchIncludeMethod takes (_ method: RouteMethod, _ on: Bool).
- BatchFillWindow counts by case and displays draft?.method?.label ?? "—".
- UITestHook emits method?.rawValue ?? "".
- RouteDraft warnings split (RoadNetwork.swift, structural, no enum needed): finish(_:warnings:lengthWarnings:notes:). The two geometry warnings (路网路径 %… 远长于直线…, 路径 %… 要在 %… 内走完…) go in lengthWarnings and are dropped when trimExcursion produced notes. This replaces the `warnings.removeAll { $0.hasPrefix("路网路径") || $0.hasPrefix("路径 ") }` filter.
- Display titles on existing String enums, with rawValues kept unchanged as ids/persisted/cache values. Each title is a `var title: LocalizedStringResource` switch with literal keys:
- ColorMode: 速度/海拔/时间/单色 (TrackData). Used in the picker and the legend.
- BaseMapStyle: 标准/卫星/混合. The rawValue stays in the snapshot cache keys.
- GlobeStyle: 写实/像素.
- AppearanceMode: 跟随系统/白天/夜间. The rawValue is persisted in UserDefaults "appearanceMode" and must never change without a read-side migration.
- DisplayMode: 单文件/重叠/对比 (TrackStore). The 1223 help text must use the same translated names.
- ExportMode (ExportSheet.swift): semantic keys exportMode.all/.year/.month/.day/.custom with defaultValue 全部/年/月/日/自定义, so they do not collide with the 年/月/日 date-row suffix keys. Replace Text(m.rawValue) at both pickers.
- Existing label properties become String(localized:), with rawValues unchanged:
- BatchKind.label 公路/铁路/跳过 (rawValues road/rail/skip);
- GapNature.label 采样稀疏/信号中断 (sparse/lol);
- RouteSource.label/detail/attribution (osrmCar/valhallaCar/overpassRail/deleteOnly). In attribution only "数据" is translated.
- TrackChange.title 补点/删除/回放点清理 (Kind fill/deletion/replay);
- SamplingProfile kindLabel/summary/derivedSummary.
- SceneID + window lookup (GPXPointViewerApp.swift): `enum SceneID { static let diff = "diff", batchFill = "batchFill", changeReview = "changeReview" }`, used in Window(id:) and every openWindow(id:).
- `extension NSApplication { func window(scene id: String) -> NSWindow? }` matches identifier?.rawValue == id or hasPrefix(id + "-"), falling back to title == String(localized: "批量补点").
- It replaces the title comparisons in TrackStore.dockBatchWindow and PointMapView.uncoveredInsets.
- The UITestHook window commands accept ids.
- Do not add an id to the main WindowGroup: that would reset saved window restoration.
- AppLanguage (GPXPointViewerApp.swift): `enum AppLanguage: String, CaseIterable, Identifiable { case system = "", zhHans = "zh-Hans", en = "en", de = "de", zhHant = "zh-Hant" }`.
- displayName: system uses the localized 跟随系统; the others are autonyms 简体中文/English/Deutsch/繁體中文.
- `static var stored` reads persistentDomain(forName:)["AppleLanguages"].
- `static let atLaunch = stored` is used for the restart hint.
- `static func apply(_:)` sets or removes AppleLanguages.
- `static func relaunch()` uses NSWorkspace.OpenConfiguration with createsNewApplicationInstance = true, then NSApp.terminate.
- Fmt namespace (new Foundation-only GPXPointViewer/L10nSupport.swift, app target plus the harness compile lines):
- `enum Fmt { static let f0, f1, f2, f3, f6, f8: FloatingPointFormatStyle<Double> }`, each `.number.grouping(.never).precision(.fractionLength(k))`;
- `static var listSeparator: String` (key list.separator, defaultValue "、").
- Endpoint sentinels: no enum needed. RouteDraft.endpoint "本地" (TrackStore delete-only) and "缓存" (RoadNetwork cached result) are never compared, so localize them at creation with String(localized:). The OSRMOutcome status tokens NoRoute/NoSegment stay ASCII and compared; only the Chinese display statuses (URL 无效, HTTP 429 限流, 非 JSON（HTTP %lld）, …) are localized. Anchor letters "A"/"B" compared in GapFill stay unlocalized; an AnchorSide enum is optional.

## 风险

- UITestHook finds alert buttons by Chinese substrings (替换/保留/插入/回放点). In any other language the lookup misses and the hook falls back to store.confirmApplyFill/confirmCleanReplays, the programmatic sheet dismissal that crashed on 2026-10-21 and 2026-10-23. Mitigation: pin every self-test launch to -AppleLanguages '(zh-Hans)' and remove the direct fallback.
- Window-title comparisons with "批量补点" (TrackStore.dockBatchWindow, PointMapView ~1502) silently stop working once Window titles localize: no docking, no inset avoidance. Must switch to scene-id lookup in Wave 0.
- Localizing identifier strings would break behavior: RouteMethod names used as dictionary keys and in == checks (BatchFillWindow counts, setBatchIncludeMethod, hook JSON, harness asserts), the persisted AppearanceMode rawValues (users' saved appearance silently resets) and the BaseMapStyle rawValues inside cache keys.
- The RoadNetwork hasPrefix("路网路径")/("路径 ") warning filter breaks the moment the warning texts are localized, unless the lengthWarnings split lands first.
- Silent non-localization: concatenations, ternaries with a String branch, ?? fallbacks, Text(variable) and String helper parameters all compile fine and just stay Chinese. Only the static audit and the 4-language runtime walk catch them.
- Placeholder-type mismatches between key and translation (%@ vs %lld, a missing positional index) can crash at runtime in String(format:)-style rendering. The parity script plus zero Xcode xcstrings warnings are mandatory.
- Number-formatting changes: FormatStyle's default grouping would turn 1234 into 1,234 and change zh-Hans output and harness substring asserts (e.g. '半径 2x'). Machine outputs accidentally converted from String(format:) (hook JSON, GapInputDump JSONL, cache keys, GPX/CSV writers, URL coordinates) would break the byte-identical harness diff or produce invalid GPX under the de decimal comma.
- Moving developmentRegion to zh-Hans is a visible behavior change. System-supplied UI (default SwiftUI menus, open/save panels, alert OK, MapKit labels) turns Chinese for Chinese users, where it is English today. Users whose languages match none of zh-Hans/en/de/zh-Hant fall back to Chinese, not English. This is a product decision to confirm with the user.
- Hand-editing project.pbxproj (no synchronized groups, sequential ids, several tab-joined multi-entry lines) can corrupt the project through duplicate ids or a missing build-phase membership. Validate with plutil -lint and xcodebuild -list after every change.
- Concurrent edits: other sessions changed TrackStore/BatchFillWindow while the inventory ran, with lines shifting by up to 51. With no checkpoint commit (only 2 commits, a large uncommitted tree), conflicting agent edits are hard to roll back. Back up first and enforce single-owner files.
- Xcode IDE re-sync: opening the project in Xcode rewrites the hand-assembled catalogs (extractionState, stale marks, formatting), and keys whose source changed later become stale. Keep the assembler idempotent and mergeable, and re-run the coverage check after any later code change.
- German layout overflow in fixed widths: 44/60pt label columns, 34–48pt numeric columns, 108pt date column, 110–150pt segmented pickers, 290/230/210/250pt panels, 380pt settings sheet, batch table columns, and the CATextLayer city label width measurement. Expect a follow-up layout pass (Grid/fixedSize) after the first German run.
- Plural handling: about 120 count-bearing keys, several with 2–5 counts. Substitutions are error-prone. Large .formatted() counts deliberately carry no plural agreement in en/de (rare "1 points"-style edge cases).
- Translation quality and volume: about 860 keys and about 2,600 strings of dense domain prose (routing, sampling heuristics, Fog of World formulas, long help texts with quoted cross-references). LLM translations need the glossary, comments and a spot review. zh-Hant must use Taiwan vocabulary, not character conversion.
- Extensions: GPXParser.swift, GeoCompute.swift and TrackShape.swift are compiled into GPXQuickLook/GPXThumbnail, where String(localized:) resolves against the appex bundle. Without the per-extension catalogs those strings fall back to Chinese.
- CLI harnesses (sampletest/garmintest) compile engine sources with swiftc. The RouteMethod type change and the Fmt/L10nSupport.swift dependency require updating their compile commands, or the offline regression baseline is lost.
- Localized strings written into files (GPX <name> "未命名轨迹"/"补点增量", default filenames) follow the UI language at creation. Exports therefore differ by language; this is accepted but should be noted to the user.
- Relaunch from the language picker loses unexported session state (fill drafts, change log, batch results). It must be guarded by a confirmation alert. Some sandbox or Gatekeeper setups may also refuse to relaunch the app's own bundle; keep the 'restart manually' caption as a fallback.

估计键数：860
