# Miledge

[English](README.md) · [プライバシーポリシー（英語）](PRIVACY.md)

**Apple「パスワード」に収まらない秘密を、自分の台帳へ。** MiledgeはMy Ledgerを表す造語です。Apple Silicon Mac・iPhone・iPad向けのSwiftUIアプリで、資格情報、アフィリエイト、健康情報を含まない保険、本人確認・税務書類、契約、鍵、メモなど30種類と独自項目を扱います。健康情報は対象外で、HealthKitも使いません。

現在のバージョンは**0.1.0**（build **2**）です。両プラットフォームを内部TestFlightグループへ配信しましたが、App Storeでは**現在は未公開**です。TestFlightへの配信は、製品や安全性の承認を意味しません。

## インストール

一般公開後はApp StoreまたはMac App Storeからインストールしてください。公開後にストアへのリンクを追加します。このリポジトリはソースと開発ツールのために使い、利用者向けバイナリは配布しません。

## 現在の実装

分類→一覧→詳細の順に操作します。Macと広いiPadウインドウでは3列、iPhoneでは標準の「戻る」で移動します。編集にはスクロール可能なフォームと固定の保存・取消を使い、任意欄、独自欄、タグ、お気に入り、関連項目を扱います。

国・地域と通貨は検索付きの選択画面、共通の分類は「その他」を備えた標準ポップアップ、日付はカレンダー、年月は月と年で選びます。既存の独自表記は保持します。新規タイトルは「種類＋登録日」を初期値とし、手動で編集・消去した後は自動変更しません。表示設定で文字サイズと秘密の初期表示を選び、秘匿欄は目のボタンと、伏せたままのコピーを使えます。

レコードは変更履歴を残すKeychainの改訂として保存します。添付はローカルで暗号化し、明示してプレビュー・書き出しを行います。暗号化バックアップと復元には標準のファイル選択を使います。競合は改訂を丸ごと選んで解消し、欄ごとの統合は行いません。未知のデータ、元の文字列、添付のバイト列は保持します。

独自アカウントや独自サーバーは設けません。現在のアプリは開発用の台帳を使い、正式な共有Keychain・iCloud設定と添付のクラウド配信は未完了です。健康情報の除外は独自項目とバックアップにも適用しますが、任意の文章・ファイルを自動で完全に判定することはできません。

**本物の秘密情報は保存しないでください。** 署名した実機での認証・永続保存、端末間同期と復旧、ネイティブUI・アクセシビリティ全体、翻訳、独立したセキュリティ承認は未完了です。TestFlight、テスト、Issue、画像には架空のデータを使ってください。

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

アプリに外部ライブラリの依存はありません。翻訳リソースは`en`、`ja`、`zh-Hans`、`zh-Hant`、`ko`、`fr`、`de`、`es`、`pt-BR`、`it`、`ar`、`hi`の12ローカライズです。母語話者の確認と全言語・RTLの表示承認は残ります。簡体字の翻訳と中国本土での配布は別々に判断します。

## 公開と変更時の注意

[公開手順](docs/release.ja.md)にGitHubの設定、署名、App Storeの手順を記載しています。アップロードにはMac・iPhone・iPadでのUI操作、製品の実行可能行の**カバレッジ90%以上**、安全性の解析、最新の準備記録、独立した署名付きセキュリティレビューが必要です。根拠が不足していれば停止します。内部TestFlightへの配信で一般公開の条件を省略しません。

Swiftには固定したオフラインのSemgrep CE 1.179.0と安全性の回帰テスト、PythonにはCodeQL 2.27.2を使います。自動解析だけで独立した監査を代替しません。

英語・日本語の文書は同時に更新してください。保存処理の変更では、未知の欄、履歴、文字列、添付の実バイトを保持します。UIは標準部品と操作時の短い通知を優先します。実在の資格情報、個人のファイル・画像、API鍵、署名証明書、秘密鍵はコミットせず、配布用の秘密は保護したGitHub environmentへ設定してください。

## ライセンス

[MIT](LICENSE)。Appleの資料と外部素材には、それぞれの利用条件が適用されます。
