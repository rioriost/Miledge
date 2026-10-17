# Build 6 内部TestFlight配信記録

- バージョン: 0.1.0 (6)
- 対象: macOS、iOS / iPadOS
- 作成日: 2026-10-17
- アップロード: 両OSともAppleの `Upload succeeded.` を確認。Apple側の処理が完了し、両OSとも内部グループで「テスト中」を確認。日本語のテストメモも保存済み。
- 配信先: 既存の Miledge Internal（内部テスター1名）

## 含まれる変更

国・地域別の電話番号・郵便番号・旅券番号の入力補助、任意の氏名構成欄と原文保持、メール・URL・カード・IBAN・BIC・ポート・VIN・OTPシード・日付の形式や前後関係の確認、拡大文字での編集ツールバー調整。詳細は [国際入力](international-input-2026-10-17.md) と [定型入力](structured-input-2026-10-17.md)。形式チェックは端末内で行い、番号・アカウントの実在を保証しない。

## 配布物の確認

Xcode 27.1 (27A9275) で両Release archiveが成功。既存の未コミット変更を含む作業ツリーを使用し、ソースのSHA-256一覧を保存。アーカイブ作成後のソース一致を確認した。

両アプリはBundle ID `st.rio.miledge`、共有Keychain group `23889H77KX.st.rio.miledge`、arm64。iOSはiPhoneとiPadの両方を含む。12言語、郵便番号規則、電話番号メタデータ、サードパーティ表記、Privacy Manifestの同梱と署名を検証した。macOSはApp Sandboxを維持。iOSは配信時の再署名ログで `get-task-allow=0` と共有Keychain groupを確認した。

iOSの初回送信用ファイル作成は、Apple標準rsyncとPATH上の別のrsyncのオプション競合で失敗した。標準システムツールだけを使うPATHで同じアーカイブを再送し成功。ソースやアプリの変更は不要だった。失敗・成功の両ログを保持する。

## 証拠

`.build/testflight-20261017-build6/` に `archive-verification.json`、`distribution-signing-evidence.json`、`source-sha256.json`、`source.diff`、`delivery.json`、両OSのアーカイブ、アップロードログ、日本語テストメモを保存。

直前の単体テスト212件とmacOS操作・iPhone/iPadシミュレーター検証は上記の入力変更記録を参照。今回のRelease archiveとアップロードは成功したが、実機でのアップデート・保存維持・iCloud到着や競合回復は未検証。内部配信はApp Review提出・一般公開・セキュリティ承認ではない。公開用の既存ゲートは変更しない。

手順参照: [Apple: Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)（2026-10-17確認）。

確認画面: [両OSのビルド6がテスト中](../artwork/testflight-20261017/build6-internal.png)。
