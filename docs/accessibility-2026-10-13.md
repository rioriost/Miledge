# 表示アクセシビリティの実装・検証記録

対象は「さらに大きな文字」「ダークインターフェイス」「カラー以外で区別」「十分なコントラスト」「視差効果を減らす」の5項目。App Storeの申告と、今回確認した画面・操作の結果を区別する。

## 対象と方法

- 基準リビジョン: `1b6b79c` と、この記録に対応する未コミットの変更。
- Xcode 27.0 (27A266a)、macOS 27.0.1、iOS/iPadOS 27.0 Simulator。
- Macは1280×800のウインドウ。iPhone 18 Pro、iPad Pro 13-inch (M5) を使用。
- 英語、合成レコード、メモリ内の保存先。実際の秘密情報、Keychain、利用者のクリップボードをテストデータに使っていない。
- 製品のSwiftUI画面をInteractionHostで起動し、ロック解除、一覧、詳細、コピー、編集、保存、新規作成、削除確認、削除を操作。iOSでは表示設定と不正な数値入力も確認。
- OSの文字サイズ・コントラストを設定。Bold Text、Reduce Transparency、Differentiate Without Color、Reduce Motionは設定画面で変更し、スイッチ値と公開UIAccessibility APIで読み戻す。
- 画面、アクセシビリティツリー、自動検査の全指摘を保存。操作テストの成功は、コントラストや文字切れの自動検査がゼロ件という意味ではない。

## 実装した変更

1. アクセシビリティ文字サイズでは、iPadを含めて項目名と入力欄を縦に並べる。最大付近のサイズでは入力欄と補助ボタンも縦に並べる。
   iPadの一覧は大きな文字で3列から1列ずつのナビゲーションへ切り替え、一覧のタイトルは行数で省略しない。装飾アイコンを省いて文字の横幅を確保する。
2. 詳細画面のコピー・表示操作を大きな文字で縦並びにする。一覧アイコンの枠を文字サイズに追従させる。
3. カスタムフォントがOSの太字設定に追従する。詳細タイトルを折り返し、iOSの上部タイトルをインライン表示にする。
4. 選択カテゴリーにチェック印を追加。高コントラスト時は選択枠にも主文字色を使う。カテゴリーは既存の名前と固有アイコンでも区別できる。
5. ロック解除などの強調ボタンに濃い青を指定。ダーク表示の明るいアクセント色と白文字の組み合わせを修正する。
6. 大きな文字で項目追加メニューのアイコンと文字が重なる箇所を修正。メニュー名を優先して全文を表示する。

## 検証結果

最終結果と残る範囲はこの節に記録する。未実施のチェックを合格扱いしない。

| 検査 | 結果 | 証拠 |
|---|---|---|
| Macのライト・ダークで主要操作 | PASS | `.build/visual-ax-mac-v5.xcresult` の2ケース |
| Macのカラー以外で区別＋OSグレースケール | PASS（主要操作） | `.build/visual-ax-mac-v6.xcresult`。OSのカラー変換は保存PNGには反映されない |
| iPhoneの実際の最大Dynamic Type＋5つのOS設定 | PASS（主要操作・不正入力時の保存禁止） | `.build/visual-ax-iphone-final-max.xcresult`、`SYSTEM_AX`の5値がtrue |
| iPadの最大Dynamic Typeで1列ナビゲーション | PASS（主要操作） | `.build/visual-ax-ipad-compact.xcresult`。3列の狭い一覧を修正後に再確認 |
| 強調ボタンのライト・ダークのコントラスト | PASS（自動検査の指摘0） | `.build/visual-ax-ipad-final.xcresult` の `testProminentActionContrast` |
| iPadの最大文字サイズで不正入力 | PASS（保存禁止・スクロール到達） | `.build/visual-ax-ipad-final.xcresult` の `testMaximumTextValidation` |
| iPhoneのAX3（200%超）で主要操作 | PASS | `.build/visual-ax-iphone-ax3.xcresult` |
| iPhoneの通常文字サイズでライト・ダークの主要操作 | PASS | `.build/visual-ax-iphone-normal.xcresult` |
| iPhoneのAX5で項目追加メニューの文字切れ修正 | PASS（表示と到達、自動文字切れ指摘0） | `.build/visual-ax-iphone-menu.xcresult` |
| Mac / iPhoneの強調ボタンのコントラスト | PASS（自動検査の指摘0） | `.build/visual-ax-mac-contrast.xcresult` / `.build/visual-ax-iphone-ax3.xcresult` |
| 関連する既存の単体テスト | PASS、15件 | `.build/visual-ax-unit-mac.xcresult`、DisplaySettings / LedgerBrowser / FieldPresentation |
| macOS / iOS Releaseビルド | PASS | `.build/visual-ax-release-mac-verified.log` / `.build/visual-ax-release-ios-verified.log` |

## 自動検査の指摘の扱い

- **実際の問題として修正**: iOSのダーク表示ではロック解除ボタンが明るい青に白文字となる。高コントラストを有効にしても残るため、強調ボタンの色を変更した。
- **実際の問題として修正**: 最大文字サイズの「Template fields」は、スクロール後もアイコンと文字が重なった。大きな文字ではアイコンを省き、全文を表示する構成に変更。再検査で文字切れの指摘は0件になった。
- **表示領域外の指摘**: 入力中の項目追加メニューはキーボードの下にある。スクロールで到達できることも確認した。画面全体の自動検査結果をそのまま表示不能と解釈しない。
- iPadでは、スクロール前のCopy、テンプレートのSearchなどにも文字切れの指摘が残る。コピー・検索を実際に操作できたことと、全指摘の解消を区別する。これらの残存指摘を含め、App Storeの包括的な申告は保留する。
- **非アクティブ画面の指摘**: Macのシート表示中に、背後で暗くなった詳細や一覧がコントラスト不足として報告される。シートの操作対象と区別する。
- **ラベルの指摘**: シンボルと文字をまとめた「Favorite」の検査指摘があった。文字を独立して折り返す構成に変更し、最大文字サイズの再検査で指摘が消えた。
- **測定で確認した例**: MacのDevice Nameは白/`#272727`で14.94:1、上部の8 itemsは`#C3C3C3`/`#202020`で9.24:1、Saveは白/`#1774DA`で4.62:1。PNGのモニターICCプロファイルをsRGBに変換して、文字内部と背景の画素を測定。全画面・全状態の保証には使わない。
- 指摘はログと添付に残す。除外によって「自動検査全件合格」とは報告しない。
- iOSの修正後の強調ボタンは白/`#0059BF`で6.60:1。最大文字サイズの項目追加メニューは`#1E6EF4`/白で4.57:1、数値エラーは`#E9152D`/白で4.56:1。色以外にもエラー文とSaveの無効状態で判断できる。

## 視差効果の検証

製品ソースには独自の`withAnimation`、`animation`、`transition`、`symbolEffect`を使った動きはない。Reduce Motionを有効にしたiPhone/Macで主要操作が完了した。iPhoneの編集シートを開く動きは録画と連続フレームで確認した。OS標準の上方向のシート移動は残る。すべての動きを止めることを合格条件にしていない。

`artwork/accessibility-20261013/iphone-reduce-motion-on.mov`と`motion-on-transition-*.png`が有効時の証拠。`.build/visual-ax-reduced-motion.mov`は初期の設定操作が反映されていなかった試行であり、**Reduce Motion無効時**の資料としてのみ扱う。`motion-off-transition-*.png`はその抜粋。両試行はタイトルのレイアウト修正をまたぐため、厳密な同一版・同一設定の動き比較ではない。

## 公開申告の範囲

Appleは、申告する機能について各デバイスで一般的な操作を完了できることを求める。この記録だけで、App Store上の5項目すべてを確定申告していない。Macの「さらに大きな文字」は現行のApp Storeラベルの対象外。アプリ独自の文字サイズ設定とは別の扱いである。

今回の確認外: 実機iPhone/iPad、全サイズのiPad、全12言語・RTL、全テンプレート、競合解消、バックアップの全段階、OSのファイル選択、添付プレビュー、実際のVoiceOver/Voice Control、すべてのキーボード操作。これらを実施したとは扱わない。既存の総合アクセシビリティ公開ゲートはblockedのまま。

App Store Connectで配信済みの0.1.0 (2)に、この未コミットの変更は含まれない。変更済みの製品ビルドのアップロードと、本記録の検証は別の作業である。

## 公式資料

2026-10-13に確認。HIG、App Storeの申告基準、SDKの挙動を混同しない。

- [Accessibility Nutrition Labelsの概要](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels)
- [Larger Text](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria)
- [Dark Interface](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/dark-interface-evaluation-criteria)
- [Differentiate Without Color Alone](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria)
- [Sufficient Contrast](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria)
- [Reduced Motion](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria)

再実行時はOSの設定と文字サイズを先に整え、`VisualAccessibilityTests`を対象デバイスごとに実行する。テスト用の`MILEDGE_AX_TEXT`だけでは、OSのシートやコントロールまで設定したことにはならない。OS設定を変えるために使った一時テストは通常のテストスイートには残さない。

検証後、Macのコントラスト・透明度・カラー以外で区別・カラーフィルタ・視差効果の一時設定を元に戻した。iPhone/iPadシミュレーターも太字・透明度・カラー以外で区別・視差効果をオフへ戻し、設定値を確認した（`.build/visual-ax-iphone-restore-v2.xcresult` / `.build/visual-ax-ipad-restore.xcresult`）。文字サイズはlarge、コントラスト増加はdisabled。設定変更用の一時テストは削除済み。

## 2026-10-14 内部配信

本記録の修正を含む0.1.0 (3)をmacOS・iOS/iPadOSともアップロードし、Miledge Internalの「テスト中」を確認。日本語のテスト案内を保存した。署名・12言語のリソース・Macのarm64とSandbox・iPhone/iPadの対応情報を確認。配布証拠は`.build/testflight-20261014/delivery.json`、ソースのハッシュは同フォルダの`source-sha256.json`。実機での受入確認とアクセシビリティの包括的申告は未完了。
