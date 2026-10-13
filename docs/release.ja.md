# App Store公開手順

[English](release.en.md) · [README](../README.ja.md)

現在のバージョンは**0.1.0**、buildは**2**です。Mac・iOS/iPadOS版は内部TestFlightへ配信しました。実機へのインストールと動作承認、独立したセキュリティ承認、一般公開の準備は未完了です。App Storeでの一般公開は行っていません。GitHubの公開ワークフローも、必要な設定と根拠が揃うまでは停止する設計を維持します。

## 1. Appleの配布設定を揃える

共有scheme `Miledge-iOS`・`Miledge-macOS`を使い、`project.yml`を変更したらXcodeGen 2.46.0で再生成します。両製品は`Miledge.app`、Bundle IDは`st.rio.miledge`、OS下限は27.0です。iOSの`UIDeviceFamily`は1・2両方とし、Macの主実行ファイルと組み込みframeworkはarm64専用にします。iOSアプリのMac・Vision Proへの自動提供は無効にします。

正式な署名チーム、共通のKeychain Access Group、iCloud Driveコンテナ、両プラットフォームのprovisioningを設定してください。MacのApp Sandboxは有効のままにします。現在の開発用台帳の動作だけで、署名した端末間の同期や添付のクラウド配信を承認しません。

アプリと保存用ターゲットには`PrivacyInfo.xcprivacy`があります。公開ごとに実際のデータ処理、Required Reason API、輸出規制を確認してください。現在の`ITSAppUsesNonExemptEncryption=false`はOS内の暗号化を使う実装に対する申告であり、暗号化や依存を変更したら再判断します。App Privacy、翻訳したストア説明、プライバシー・サポートURL、対応機器、提供地域も確認します。簡体字の翻訳だけで中国本土の提供を決めません。

build番号は新しい値を使ってください。**2はアップロード済み**です。ビルドやアップロードは、App Reviewへの提出・公開とは別です。

## 2. GitHubの設定と秘密を保護する

独立した承認者と保護した`v*`タグを使う`app-store` environmentを作成します。既定ブランチを保護し、無断のタグ置換・削除を防いでください。同等の承認を強制できない場合は、配布用の秘密を設定しません。

署名には、使い捨てのGitHub-hosted Apple Silicon macOS runnerを使います。共有の作業用Macや永続するself-hosted runnerは使いません。アップロード処理がKeychainの検索順を一時変更するためです。OS 27.0と無人のMac XCUITestに対応するrunner・Xcodeを固定し、自動操作できない場合はテストを省略せず停止します。

承認前にも必要となるrepository variablesを設定します。

| 変数 | 必要な値 |
| --- | --- |
| `RELEASE_RUNNER` | 明示した対応macOSラベル。`macos-latest`は使わない |
| `XCODE_DEVELOPER_DIR` | 使用するXcodeの`Contents/Developer`への絶対パス |
| `XCODE_VERSION`・`XCODE_BUILD_VERSION` | `xcodebuild -version`の正確な版・build |
| `XCODE_PROJECT` | `Miledge.xcodeproj` |
| `APPLE_TEAM_ID` | 正式な署名チームの識別子 |
| `KEYCHAIN_ACCESS_GROUP` | 正式なチーム接頭辞を含む共通グループ |
| `ICLOUD_CONTAINER_ID` | 共通の`iCloud.…`コンテナ |
| `IOS_SCHEME`・`MACOS_SCHEME` | `Miledge-iOS`・`Miledge-macOS` |
| `IOS_TEST_DESTINATION` | 導入済みのiPhone：`platform=iOS Simulator,name=<device>,OS=<exact version>` |
| `IPAD_TEST_DESTINATION` | 導入済みのiPad：`platform=iOS Simulator,name=<device>,OS=<exact version>` |

`IOS_BUNDLE_ID`・`MACOS_BUNDLE_ID`はワークフローが`st.rio.miledge`に固定します。シミュレーターのOSは27.0以降です。

配布用の秘密は、保護した`app-store` environment secretsだけに保存します。

| Secret | 内容 |
| --- | --- |
| `ASC_KEY_ID`・`ASC_ISSUER_ID` | App Store ConnectのチームAPI鍵の識別子 |
| `ASC_PRIVATE_KEY` | 改行を含む`.p8`秘密鍵の全文 |
| `SIGNING_CERTIFICATES_P12` | 証明書・秘密鍵を含むPKCS#12の1行base64 |
| `SIGNING_CERTIFICATES_PASSWORD` | PKCS#12のパスワード |

PKCS#12には必要な署名・インストーラーのidentityを含めます。アップロードはAppleのツールと`-allowProvisioningUpdates`を使い、Apple側の署名設定を変更する可能性があります。API鍵だけでは署名できません。

信頼する`SECURITY_REVIEWER_ID`・`SECURITY_REVIEW_PUBLIC_KEY`は保護したenvironment variablesに設定します。後者は独立したレビュー担当者のRSA/ECDSA公開鍵PEMです。所有者をリポジトリ外で確認し、担当者の秘密鍵はコミット・アップロードしません。

## 3. 公開判定を省略しない

公開ツールにはPython 3.10以降とOpenSSLを使います。

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/coverage.py swift --measure --report .build/gates/package-llvm.json
```

変数と対応する公開タグを設定した環境では、次を実行します。

```sh
python3 scripts/release.py test --platform ios
python3 scripts/release.py test --platform macos
```

各ネイティブのテスト先で、架空データの実操作を先に実行し、続けてRelease構成で`App/`・`Sources/`の製品全ソースを計測します。iPhoneとiPadは別々に実行します。UIテストは1件以上を順次実行し、再試行・失敗・スキップ・構造化された実行時警告を認めません。UIのカバレッジは無効です。Macの実操作にはad-hoc署名と動作する自動操作環境が必要です。専用アプリは製品の認証・永続保存を使わないため、架空データの結果でそれらを承認しません。

製品の実行可能行のカバレッジは、各テスト先で**90%以上**を必要とします。対象外・未計測のファイルや、UI・保存処理の除外は認めません。テスト用のtestability・計測設定は配布archiveに持ち込みません。Packageの計測は追加の要件で、ネイティブの代わりにはなりません。

Swiftの解析はSemgrep CE 1.179.0、ハッシュ固定の依存、独自ルールの回帰テストを使います。解析はオフラインで、抑制を無効にし、製品ソースと構文解析の一覧を照合します。PythonはCodeQL 2.27.2の`security-extended`です。リポジトリの公開範囲とGitHubプランに対するCodeQLの利用条件も確認してください。自動解析を独立した監査とは扱いません。

判定の記録はソースのハッシュ、commit、run、attemptに結び付けます。アップロード前に再検査し、欠落・古い・一部だけ・対象不一致の記録があれば、署名情報を読む前に停止します。

`release-readiness.json`には、バックアップ移行、翻訳、署名した端末・機器、アクセシビリティ、競合の復旧について、実質的な成功の根拠が必要です。現在は停止中です。最終ソースのdigestは次で取得します。

```sh
python3 scripts/gates.py readiness-digest
```

digest自体は準備完了の証拠ではありません。実機の認証・Keychain・バックアップ、クラウド配信と復旧、キーボード・VoiceOver・外観、12言語の承認、最新の機器互換性を確認してから承認します。

`release-security-review.json`も別の停止条件です。実装担当者から独立した担当者が、記録されたiOS MASVS/MASTG、Mac、解析の不足範囲をすべて確認し、指摘を解消して残るリスクを記載します。秘密を含まない最終報告書だけを`docs/security-reviews/`へ置き、SHA-256と最終ソースのdigestを記録して、manifestの正確なバイト列へ署名します。

```sh
openssl dgst -sha256 -sign <reviewer-private-key.pem> \
  -out docs/release-security-review.sig docs/release-security-review.json
```

報告書・manifest・署名はコミットしますが、秘密鍵は入れません。製品・テスト・ツール・ワークフローを変えたら再レビューが必要です。environmentの承認で、この判定を省略しません。

## 4. アップロード・テスト・公開を分ける

レビュー済みの変更に、版と一致する不変の`vX.Y.Z`タグを作成します。**Actions → Upload App Store build**でそのタグ、同じ版、9桁以内の新しい正整数build番号、対象OSを選びます。初回一般公開は`all`を選びます。

ワークフローは事前確認、両OSのUI・カバレッジ、Packageの計測、安全性の解析を行い、保護したアップロード承認を待ちます。archiveの識別子、CPU、機器、12言語の空でないリソース、sandbox、debugger権限がないことを確認し、`xcodebuild -exportArchive`の`app-store-connect`で送信します。判定JSONとdSYMは保持しますが、署名鍵や個人データは保持しません。runnerの強制終了で後片付けが中断する場合があるため、使い捨ての環境が必要です。

App Store ConnectでApple側の処理完了を確認します。片方だけ成功した場合、受理されたbuild番号を再利用しません。まず架空データの内部TestFlightを使い、外部テストでは必要なBeta App Reviewを受けます。最終ソースと端末ごとの承認、更新・復旧時の動作も確認します。

App Reviewへの提出と一般公開は手動で行います。架空の確認手順、承認済みのストア・プライバシー・輸出情報を用意し、実際の台帳は渡しません。両プラットフォームを揃えて承認後の手動公開を選び、提供を確認してからREADMEへストアリンクを追加します。

重大な不具合では、必要に応じて未公開・段階公開を停止し、新しいbuildを提出します。App Storeの即時rollbackを前提にせず、データを読めない古いスキーマへ戻しません。

## 配布に関する確認先

- [App Storeへの提出](https://developer.apple.com/app-store/submitting/)・[ビルドのアップロード](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)：公開時のSDK要件と処理条件を再確認する。
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)：プライバシー、健康情報の除外、審査・提供条件。
- [輸出規制](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)・[Required Reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)：実装に基づいて申告する。
