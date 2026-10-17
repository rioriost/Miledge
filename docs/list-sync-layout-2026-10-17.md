# macOS同期到着時の一覧表示崩れ

## 確認した現象

macOS 27.0.1 (26A434)、Xcode 27.1 (27A9275)、Releaseで再現。日本語、小さい文字、840 × 650のウインドウ、幅240ポイントの一覧。旅券を表示したまま先頭に運転免許証が到着すると、新しい行の内容に必要な高さは52ポイントなのに、ネイティブ行の高さが24ポイントのままになる。選択の有無にかかわらず再現した。データの到着後の描画の問題であり、この再現自体はAppleの端末間転送を検証するものではない。

## 修正

macOSの一覧をAppKitの標準NSTableViewで表示し、表示するSwiftUIの行そのものから高さを測る。内容・列幅・文字サイズの変更時に高さを更新する。UUIDによる選択、並べ替え、検索、カテゴリ、詳細表示は既存のLedgerBrowser / LedgerViewを維持する。iOSは既存のSwiftUI Listを使用する。

表自体の同一性を維持し、同期前にスクロールしていた場合は先頭の見えている項目とその位置を復元する。先頭を表示している場合は、先頭に追加された項目をそのまま表示する。表示のみのセルは入力を受け取らず、ポインタとキー入力を標準の表に渡す。

## 検証記録

- 基準: `.build/list-sync-20261017/baseline-narrow-top.xcresult` / `baseline-release.xcresult`。24対52ポイントの不一致で失敗。
- 修正後初回: `native-table.xcresult`。一覧モデル6件、ネイティブ表示4件の10件が成功。
- 最終テスト: `final-regression.xcresult` / `final-regression.log`。一覧モデル6件、ネイティブ表示4件の10件が成功。サイズ変更なしでの文字拡大・縮小と、スクロールの先頭表示項目の維持も検証。
- 同期セッションの単体テスト8件成功。孤立したメモリ上の記録を使用し、ユーザーのKeychainを読書きしていない。
- iOS Releaseビルド成功: `ios-final-build.log`。
- 検証用アプリで、5秒ごとの通常更新からの到着を再現。行をクリックせず2行が正しく表示され、選択中の旅券は維持された。
- Light / Darkで表示と選択ハイライト、カテゴリ変更で0件になったときの選択解除、全項目へ戻したときの記録の保持を確認。
- Darkで最大文字への拡大・縮小、クリック、一覧へフォーカスを置いて上下キーで項目と詳細が切り替わることを確認。
- 実行時アクセシビリティツリーで、表・行・選択状態・完全な項目名と種類を確認。実際のVoiceOverによる読み上げ操作は未実施。

確認画像: [同期後](../artwork/sync-layout-20261017/after-arrival-dark.png)、[Light](../artwork/sync-layout-20261017/after-arrival-light.png)、[最大文字](../artwork/sync-layout-20261017/after-arrival-largest-dark.png)、[縮小後](../artwork/sync-layout-20261017/after-font-reduction-dark.png)。NSHostingControllerを直接使うテストには、変更前と同じツールバー内部の制約警告が残る。実ウインドウで対象の行が読めることを別途確認した。テストのホスト内ビットマップは合成レイヤーを正しく取り込めないため、表示の判定には検証用アプリの実ウインドウを使用した。

## 検証中の終了ダイアログ

16:03の自動テスト2件で、AppKitのキーボードコマンドをテストから直接呼んだ後、XCTestの非同期エラー観測中にSwift concurrencyのメモリ解放エラーで検証プロセスが終了した。PID 82443 / 83008は該当するテスト実行ログと一致し、両クラッシュスタックにXCTestがある。TestFlight実機版のクラッシュを示す証拠ではない。直接コマンド呼び出しを除き、検証用アプリへの実際のキー操作に切り替えた。クラッシュ記録と失敗した結果は保持する。

## 根拠と範囲

2026-10-17にAppleの現行資料を確認した。

- APPLE-HIG: [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)、[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)、[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)。狭い幅での可読性、選択の可視化、文字サイズへの対応を確認基準とした。特定の行高をHIGの義務として扱っていない。
- APPLE-SDK: [List](https://developer.apple.com/documentation/swiftui/list)、[NSTableView](https://developer.apple.com/documentation/appkit/nstableview)、[noteHeightOfRows](https://developer.apple.com/documentation/appkit/nstableview/noteheightofrows(withindexeschanged:))。UI部品の仕様とHIGの設計指針は区別する。
- OBSERVATION: 上記の行高不一致、最終結果、画像、操作、AX情報。

全言語、実際のVoiceOver、他のmacOSバージョン、実機間のiCloud到着・競合は今回の確認対象外。ビルド番号とTestFlight配布状態は変更していない。
