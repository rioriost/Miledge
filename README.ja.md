# Miledge

[English](README.md) · [プライバシーポリシー（英語）](PRIVACY.md)

**Apple「パスワード」に収まらない秘密を、自分の台帳へ。** MiledgeはMy Ledgerを表す造語です。Apple Silicon Mac・iPhone・iPad向けのSwiftUIアプリで、資格情報、アフィリエイト、健康情報を含まない保険、本人確認・税務書類、契約、鍵、メモなど30種類と独自項目を扱います。健康情報は対象外で、HealthKitも使いません。

現在のバージョンは**0.1.0**（build **7**）です。両プラットフォームを内部TestFlightグループへ配信しましたが、App Storeでは**現在は未公開**です。TestFlightへの配信は、製品や安全性の承認を意味しません。

## インストール

一般公開後はApp StoreまたはMac App Storeからインストールしてください。公開後にストアへのリンクを追加します。このリポジトリはソースと開発ツールのために使い、利用者向けバイナリは配布しません。

## 現在の実装

分類→一覧→詳細の順に操作します。Macと広いiPadウインドウでは3列、iPhoneでは標準の「戻る」で移動します。編集にはスクロール可能なフォームと固定の保存・取消を使い、任意欄、独自欄、タグ、お気に入り、関連項目を扱います。

国・地域と通貨は検索付きの選択画面、共通の分類は「その他」を備えた標準ポップアップ、日付はカレンダー、年月は月と年で選びます。既存の独自表記は保持します。新規タイトルは「種類＋登録日」を初期値とし、手動で編集・消去した後は自動変更しません。表示設定で文字サイズと秘密の初期表示を選び、Macでは秘匿値をマウスオーバーで表示し、クリックでコピーします。iOSではタップで表示し、コピー操作を選べます。

レコードは変更履歴を残すKeychainの改訂として保存します。添付はローカルで暗号化し、明示してプレビュー・書き出しを行います。暗号化バックアップと復元には標準のファイル選択を使います。競合は改訂を丸ごと選んで解消し、欄ごとの統合は行いません。未知のデータ、元の文字列、添付のバイト列は保持します。

独自アカウントや独自サーバーは設けません。現在のアプリは開発用の台帳を使い、署名したアプリは共有Keychainアクセスグループを使い、新規記録をiCloud Keychainで同期します。添付ファイルは端末内に留まります。健康情報の除外は独自項目とバックアップにも適用しますが、任意の文章・ファイルを自動で完全に判定することはできません。

**本物の秘密情報は保存しないでください。** 署名した実機での認証・永続保存、端末間同期と復旧、ネイティブUI・アクセシビリティ全体、翻訳、独立したセキュリティ承認は未完了です。TestFlight、テスト、Issue、画像には架空のデータを使ってください。

## Miledgeが使えなくなったときにデータを取り出す

Macに記録が残っているか、同じApple AccountからiCloud Keychainの記録を同期できれば、Miledgeを起動せずに本文を取り出せる設計です。まず以下の手順でJSONを保存し、続く説明で内容と履歴を読み取ってください。添付と暗号化バックアップの形式は、この節の後半に記載しています。

この手順は現在のソースとAppleの仕様に基づきます。Miledgeの署名した実機データを使った一連の取り出し操作は未検証です。アプリを削除した後もデータが必ず残ることや、未同期の記録を別の端末で取得できることは保証しません。元の端末やアプリ内のファイルを消す前に、取り出した内容を確認してください。

### キーチェーンアクセスで本文のJSONを保存する

1. MacのSpotlightで「キーチェーンアクセス」を検索して開きます。Appleの「パスワード」アプリとは別のアプリです。
2. キーチェーン一覧から「iCloud」または「ローカル項目」を選び、「すべての項目」または「パスワード」を表示します。記録を保存したMacを使うか、同期対象の記録については同じApple AccountでiCloud Keychainを有効にしてください。`device-local`の記録は元の端末にしかありません。
3. `st.rio.miledge.development.revisions`を検索します。現在のアプリはこのサービス名を使います。見つからなければ、検索を`miledge`に広げ、キーチェーンアクセスを終了して開き直してください。タイトルはKeychainの検索用属性に保存していないため、記録のタイトルでは探せません。
4. 対象項目を開き、「パスワードを表示」を選んでmacOSの認証を行います。「パスワード」欄に保存されているのが、その改訂全体のJSONです。アカウント属性の`recordId/revisionId`も控えます。
5. JSON全体をコピーし、テキストエディタで標準テキスト・UTF-8として保存します。ファイル名は`revisionId.json`など、改訂を区別できるものにします。テキストエディットでは「フォーマット」→「標準テキストにする」を選び、`.txt`が自動追加されないか確認してください。
6. 同じサービスの項目をすべて保存します。項目は記録ごとではなく改訂ごとに分かれており、編集前の内容や削除の記録も含まれます。コピーの途中で省略されていないか、末尾まで確認してください。JSON中の`\n`や`\u…`などは文字の表現なので、原本では書き換えずに残します。

コピーしたJSONには、画面で隠していた値も含まれます。保護した場所で作業し、オンラインのJSON整形サービスなどに貼り付けないでください。取り出しのために元のKeychain項目を編集・削除する必要はありません。

Appleの資料：[キーチェーン内の情報を表示する](https://support.apple.com/guide/keychain-access/kyca1085/mac)、[TN3137: MacのKeychain実装とUI](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。データ保護キーチェーンのパスワード項目はキーチェーンアクセスの表示対象です。`security`コマンドは主に従来のファイル型Keychain向けなので、この手順の代わりにはしていません。

### 保存形式と改訂履歴を読む

本文は**改訂1件につき1個のUTF-8 JSONオブジェクト**です。Keychainの汎用パスワード（`kSecClassGenericPassword`）のデータ部分（`kSecValueData`）に入り、Keychain自体の暗号化とアクセス制御で保護されます。本文にMiledge独自の追加暗号化はありません。macOSではデータ保護キーチェーンを使い、アクセスグループは`$(AppIdentifierPrefix)st.rio.miledge`です。`$(AppIdentifierPrefix)`は署名時に置き換わる接頭辞です。

| 属性・JSONキー | 意味 |
| --- | --- |
| Keychainのサービス／アカウント | `st.rio.miledge.development.revisions`／`recordId/revisionId`（UUIDは大文字・小文字を同一視） |
| `schemaVersion` | 現在は`1`。本文形式の版 |
| `recordId`、`revisionId` | 同じ記録をまとめるIDと、各改訂を識別するID |
| `parentRevisionIds` | この改訂が引き継いだ改訂のID。最初の改訂は空配列 |
| `templateId`、`templateVersion`、`title` | 項目の種類、その版、タイトル |
| `storageScope` | `synchronizable`はiCloud Keychain同期対象、`device-local`は端末内のみ。同期完了を表す値ではありません |
| `createdAt`、`modifiedAt` | UTCの日時文字列（ISO 8601、末尾`Z`） |
| `sections[].fields[]` | 各欄の`id`、`kind`、`value`、`concealed`、任意の`label`。実際の内容は`value` |
| `tags`、`favorite`、`linkedRecordIds` | タグ、お気に入り、関連する記録のID |
| `deleted` | `true`なら、その改訂は記録の削除を表します |
| `attachments` | 添付の名前・形式・復号鍵など。ファイル本体は含みません |

`value`は通常は文字列で、数値・日付・年月も文字列として扱います。種類によっては真偽値、配列、オブジェクトになります。例えば住所はオブジェクト、複数選択は文字列配列、リカバリーコードは`id`・`code`・`used`を持つオブジェクトの配列です。`concealed: true`は画面で隠す指定であり、`value`の追加暗号化ではありません。欄の表示名が分からなければ、`label`と`id`、[TemplateCatalog.swift](Sources/MiledgeDomain/TemplateCatalog.swift)を参照してください。未知のキーや元の文字列も、そのまま保管します。

次は架空の記録です。実際のJSONは改行なしで保存されます。

```json
{
  "schemaVersion": 1,
  "recordId": "11111111-1111-4111-8111-111111111111",
  "revisionId": "22222222-2222-4222-8222-222222222222",
  "parentRevisionIds": [],
  "templateId": "custom-item",
  "templateVersion": 1,
  "storageScope": "synchronizable",
  "title": "Example",
  "tags": [],
  "favorite": false,
  "createdAt": "2026-10-24T00:00:00Z",
  "modifiedAt": "2026-10-24T00:00:00Z",
  "deleted": false,
  "sections": [{"id": "notes", "fields": [
    {"id": "body", "kind": "string", "value": "Example text", "concealed": true, "label": "Memo"}
  ]}],
  "attachments": [],
  "linkedRecordIds": []
}
```

現在の内容を選ぶときは、次の順序で確認します。

1. JSONを`recordId`ごとにまとめ、各`revisionId`と`parentRevisionIds`を照合します。参照される親改訂が欠けていたら、まずそのJSONを探してください。循環した参照や別の記録への親参照がある場合も、正常な履歴として扱えません。
2. 同じ記録のどの改訂からも親として参照されていない改訂が、履歴の先端です。1件なら、それが現在の状態です。`deleted: true`なら削除済みとして扱います。削除前の内容を回収したい場合は、親をたどって以前の改訂を読みます。
3. 先端が複数あれば競合です。それぞれの内容を比較して、必要な値を手動で回収します。`modifiedAt`の最大値だけで1件に決めないでください。競合解消済みの改訂は、複数の先端を`parentRevisionIds`に持ちます。

これで各欄の内容を読み取り、別の保管先へ手動で移せます。JSONファイルをKeychainへ戻すだけで、Miledgeに安全に再登録できるわけではありません。

### 添付には元の端末のファイルとJSON内の鍵が必要

現在の添付は`device-local`の記録のみが対象で、iCloud Keychainには同期されません。Macの保存先は通常、`~/Library/Containers/st.rio.miledge/Data/Library/Application Support/Miledge/DeviceLocalBlobs/`です。実際にはアプリのApplication Supportディレクトリ内の`Miledge/DeviceLocalBlobs/`を使います。ファイル名は小文字の`blobId.miledgeblob`です。このディレクトリはOSのバックアップ対象から除外する設定なので、別途書き出した添付やMiledgeの暗号化バックアップも保管してください。

JSONの`attachments[]`には、`blobId`、`originalFilename`、`mediaType`、`plaintextSize`（10進文字列）、`formatVersion`（`"1"`）、`algorithm`（`"AES-GCM"`）、`key`（32バイトの鍵のBase64表現）があります。ファイル形式1は、先頭21バイトが`MILD`の4バイト＋版`0x01`＋UUIDの16バイトで、続いて12バイトのnonce、暗号文、16バイトの認証タグが並びます。

手動で復号する場合は、原本のコピーを使い、`blobId`が一致するJSONから鍵をBase64デコードします。AES-256-GCMに対応したツールで、その鍵・nonce・暗号文・タグと、先頭21バイト全体を追加認証データ（AAD）として指定してください。認証成功後、復号結果のバイト数が`plaintextSize`と一致することを確認して保存します。キーチェーンアクセスだけでは、この復号はできません。ファイル本体か鍵のどちらかが失われた場合も復元できません。実装の詳細は[EncryptedBlobStore.swift](Sources/MiledgeStorage/EncryptedBlobStore.swift)と[AttachmentService.swift](Sources/MiledgeApplication/AttachmentService.swift)を参照してください。

### 暗号化バックアップはmacOSの標準コマンドで取り出す

`.miledge-backup`はパスフレーズで暗号化したApple Encrypted Archive（AEA1、profile 5: `hkdf_sha256_aesctr_hmac__scrypt__none`、圧縮なし、ブロック64 KiB）です。復号後はバイナリProperty List（`bplist00`）で、`formatVersion: 1`、`revisions`、`blobs`を持ちます。`revisions`は各改訂のUTF-8 JSONのデータ配列、`blobs`は`metadata`・`bytes`・`scope`を持つ添付の配列です。バックアップ内の`bytes`は、AEAを復号した後は元の添付バイト列なので、前述のAES-GCM復号は不要です。

バックアップとパスフレーズがあれば、Mac標準の`aea`、`plutil`、`base64`を使えます。保護した作業フォルダにバックアップのコピーを`backup.miledge-backup`という名前で置き、パスフレーズだけをUTF-8・BOMなし・末尾改行なしの`backup-password.txt`として保存します。空白やUnicode文字の表記も変更しないでください。ターミナルでそのフォルダへ移動し、次を実行します。

```sh
umask 077
set -o pipefail
chmod 600 backup-password.txt
aea decrypt -i backup.miledge-backup -o recovered.plist -password backup-password.txt
plutil -convert xml1 -o recovered.xml recovered.plist
plutil -extract revisions.0 raw -o - recovered.plist | base64 -D > revision-0.json
plutil -extract blobs.0.bytes raw -o - recovered.plist | base64 -D > attachment-0.bin
```

各コマンドの成功を確認してから次へ進んでください。`recovered.xml`で配列の件数と内容を確認し、`0`を`1`、`2`…に変えて存在する要素を順に取り出します。`blobs`が空なら添付のコマンドは不要です。添付は`metadata.blobId`と改訂の`attachments[].blobId`を照合して元の名前を確認します。改訂と添付の配列順が対応するとは限りません。JSONの履歴は上記の手順で読み取ります。

これらのコマンドは架空のAEA/profile 5・Property Listデータで動作確認しています。Miledgeが書き出した実機バックアップとの一連の確認は未完了です。パスフレーズファイルと復号後のJSON・Property List・添付は秘密情報をそのまま含むため、回収後も残すものは保護し、不要な作業用コピーは削除してください。

## ビルドとテスト

Xcode 27・Swift 6.4・XcodeGen 2.46.0・Python 3.10以降を使います。最低対応OSはmacOS・iOS・iPadOS 27.0です。Macはarm64専用で、iOSはiPhoneとiPadの両方を対象にします。公開前にはAppleの最新の対応機器を確認してください。

```sh
xcodegen generate
swift test --enable-code-coverage
python3 -m unittest discover -s scripts/tests -v

xcodebuild -project Miledge.xcodeproj -scheme Miledge-macOS \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```

未署名のコマンドで確認するのはコンパイルであり、認証やKeychainの動作ではありません。シミュレーターや署名した実機での開発には`Miledge.xcodeproj`をXcodeで開き、必要に応じて自分の署名チームを設定してください。

Macで起動するローカル製品には、未署名やカバレッジ計測用のbundleではなく、ad-hoc署名を使います。

```sh
xcodebuild -project Miledge.xcodeproj -scheme Miledge-macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/development-macos build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
```

製品schemeは`Miledge-iOS`・`Miledge-macOS`です。両方とも**`Miledge.app`**を出力し、Bundle IDは**`st.rio.miledge`**です。開発用Keychainサービスは`st.rio.miledge.development.revisions`で、端末間共有を正式に承認した台帳ではありません。

| パス | 内容 |
| --- | --- |
| `Sources/` | データモデル、Keychain・暗号化保存、アプリ処理。Swift Packageでも同じソースを使用 |
| `App/` | 共通のSwiftUI画面、標準入力部品、翻訳、AppIcon |
| `Tests/`・`AppTests/` | ライブラリとネイティブアプリのテスト |
| `InteractionHost/`・`InteractionTests/` | 架空データのUIアプリと実際の操作部品のテスト |
| `project.yml`・`Miledge.xcodeproj/` | XcodeGenの定義と生成済みプロジェクト・共有scheme |
| `scripts/`・`.github/workflows/` | 検証、カバレッジ、安全性の解析、条件付きのApp Storeアップロード |

`MiledgeInteraction-iOS`・`MiledgeInteraction-macOS`は架空データとメモリー内の処理を使い、個人のKeychain、実際の認証、通常クリップボードにはアクセスしません。製品のarchiveにも含めません。この結果を製品の永続保存の確認とは扱いません。

電話番号の解析にはPhoneNumberKitを使い、郵便番号ルールとライセンス表示を同梱しています。入力値を照会サービスへ送信しません。翻訳リソースは`en`、`ja`、`zh-Hans`、`zh-Hant`、`ko`、`fr`、`de`、`es`、`pt-BR`、`it`、`ar`、`hi`の12ローカライズです。母語話者の確認と全言語・RTLの表示承認は残ります。簡体字の翻訳と中国本土での配布は別々に判断します。

## 公開と変更時の注意

[公開手順](docs/release.ja.md)にGitHubの設定、署名、App Storeの手順を記載しています。アップロードにはMac・iPhone・iPadでのUI操作、製品の実行可能行の**カバレッジ90%以上**、安全性の解析、最新の準備記録、独立した署名付きセキュリティレビューが必要です。根拠が不足していれば停止します。内部TestFlightへの配信で一般公開の条件を省略しません。

Swiftには固定したオフラインのSemgrep CE 1.179.0と安全性の回帰テスト、PythonにはCodeQL 2.27.2を使います。自動解析だけで独立した監査を代替しません。

英語・日本語の文書は同時に更新してください。保存処理の変更では、未知の欄、履歴、文字列、添付の実バイトを保持します。UIは標準部品と操作時の短い通知を優先します。実在の資格情報、個人のファイル・画像、API鍵、署名証明書、秘密鍵はコミットせず、配布用の秘密は保護したGitHub environmentへ設定してください。

## ライセンス

[MIT](LICENSE)。Appleの資料と外部素材には、それぞれの利用条件が適用されます。
