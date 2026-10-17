# 国・地域別の入力チェックと氏名の構成要素

## 実装範囲と保存方針

- macOS / iOS / iPadOS の既存編集フォームに追加。最低対応 OS 27.0、Schema 1、テンプレート版 1、Keychain の保存・同期方式は変更しない。
- 電話番号は PhoneNumberKit **5.0.12** を固定して使用。国内表記にはその電話番号の国・地域を明示的に指定する。`+` 付きは入力された国番号を優先し、端末の地域や旅券の国籍から推測しない。内線、全角数字、Unicode の十進数字を比較用に扱う。短縮番号・特殊番号などの不一致も保存できる。
- 住所は国・地域、郵便番号、州・都道府県、市区町村、番地を任意に追加できる。独自の住所成分も保持する。Google の住所メタデータから **252 地域・182 郵便番号パターン**を同梱。国レベルの形式だけを照合する。郵便番号の割り当てや住所との対応、住所の実在は確認しない。
- 旅券番号は**発行国**を参照。日本（英字 2 + 数字 7）と米国（数字 9、または英字 1 + 数字 8）の一般的な現行形式を照合。国籍とは区別する。他国・不明・独自の発行主体は未チェック。古い書類、特殊書類、旅券カードの厳密な種別判定、MRZ 全体のチェックディジット検証は対象外。
- 形式一致・要確認・未チェックを文字と記号で区別する。入力値をエラーメッセージに埋め込まない。未入力は任意項目として扱い、形式チェックの警告は保存を妨げない。構造破損・重複住所キー等の既存の保存制約は維持する。
- 検証は端末内で完結する。入力データを外部 API、電話の発信先、住所検索サービスへ送らない。比較用の大文字化・幅変換・数字変換を保存値に反映しない。
- 電話番号の国・地域は同じセクションの `phone-region:<fieldID>` という通常の文字列フィールドで保持。旧版でも消えない形式とし、電話欄を削除すると同じセクションの関連する国・地域欄も削除する。旧版から残った孤立した国・地域欄は、独立した項目として表示・削除できる。
- 氏名全体は原文のまま残す。名・ミドルネーム・姓・前につく敬称・後ろにつく接尾辞・元の文字体系での氏名は任意。自動分割、表示順の自動変更、姓やミドルネームの必須化は行わない。複合姓、単名、非ラテン文字、先頭・末尾空白を保持する。
- 氏名詳細は Identity / Passport / Driver License / Membership / Outdoor License / Reward Program / Government Identifier / Residence Document / Credit Card / Bank Account に追加可能。古い Identity の名・姓がある場合は重複追加しない。
- 新しいラベル・説明・結果文言 26 件を既存の 12 言語すべてに追加。

## 根拠と設計判断

調査日: 2026-10-17。下記の規格・データは HIG や App Review 規則とは別の根拠。

| 根拠 | 採用した範囲 |
| --- | --- |
| [ICAO Doc 9303 Part 4](https://www.icao.int/sites/default/files/publications/DocSeries/9303_p4_cons_en.pdf), §4.2.2 / MRZ 下段 | MRZ の旅券番号欄は発行主体が付与した番号の機械可読表記。MRZ の規定から、あらゆる可視旅券番号に共通の 9 文字制約があるとは推論しない。 |
| [神奈川県パスポートセンター](https://www.pref.kanagawa.jp/docs/h6d/passport/aboutpass.html) | 日本の旅券番号の英字 2 文字・数字 7 桁。 |
| [US Department of State: Security Features and Design](https://travel.state.gov/en/passports/apply/help/security-design.html) | Next Generation Passport の英字 1 + 数字 8。旧デザインの旅券が有効な場合もある。 |
| [AAMVA: Passport Number](https://www.aamva.org/d20trafficrecordssystemsdatadictionaryjson/29507.htm), 2026-02-18 | 米国の従来の 9 桁数字を含む複数形式。一般論の ICAO 記述にはこのページを用いない。 |
| [W3C: Personal names around the world](https://www.w3.org/International/questions/qa-personal-names) | 同じ地域でも名前構造は一律でない。全体の原文を保持し、必要な構成要素だけ任意追加する設計判断。 |
| [PhoneNumberKit 5.0.12](https://github.com/PhoneNumberKit/PhoneNumberKit/releases/tag/5.0.12) | Google libphonenumber に基づく同梱番号計画を利用。ライブラリの判定は実在確認ではない。明示された国番号から解析用地域を決める。 |
| [Google Address Validation Metadata](https://github.com/google/libaddressinput/wiki/AddressValidationMetadata) | `zip` の国レベル正規表現を利用。地方・都市レベルの接頭辞照合までは行わない。 |

郵便番号データは `scripts/update-postal-rules.py` で公開データを取得した派生スナップショット。取得日、各応答の SHA-256、例、使用有無を `PostalRules.json` に記録。更新スクリプトは開発時専用であり、アプリから呼び出さない。PhoneNumberKit の MIT および Google メタデータの Apache 2.0 通知は `ThirdPartyNotices.txt` として同梱。

## Apple HIG の設計契約

既存の SwiftUI Form とネイティブ入力欄を維持。明示ラベル、入力欄の近くの訂正案、国選択、全文保存、標準のキーボード操作・貼り付け、折り返し、色だけに頼らない状態表示を対象とする。国の選択は iPhone / iPad では標準検索フィールドと一覧を持つシート、macOS では検索フィールドを持つポップオーバー。iPad の編集画面と国選択画面がツールバー状態を共有しない構成にし、国変更後も保存操作を維持する。App Review 提出可否や全体の HIG 適合認証を意味しない。

| 現行 Apple 一次資料 | 取得日時 UTC | SHA-256 / 適用 |
| --- | --- | --- |
| [Entering data](https://developer.apple.com/design/human-interface-guidelines/entering-data) | 2026-10-17 02:23:20 | `72db13f9ccb322585c1ed03f9dff57126844e3ade47e86a5c1f9972f7d5f4f37` — 入力の負担、選択肢、適時のフィードバック |
| [Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields) | 2026-10-17 02:23:20 | `a0b575085d2380e038d4b610e51d0fac341896dea802e5b2c4c86270701a3ccc` — ラベル、適切なキーボード、標準編集 |
| [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | 2026-10-17 02:36:50 | `8963a528599921939efb883c3a5cbb0b706e6d8d2abd9e712e71b9197e061d58` — 拡大文字、標準色、非色依存の表示 |
| [Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) | 2026-10-17 02:36:50 | `207c0ad6222be9507b7f678990dccf91c4fe470ddfb9c6ef4df6076b7712c936` — タッチ、Dark Mode / Dynamic Type |
| [Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) | 2026-10-17 02:57:17 | `4f40bca3b4211c0b2efb57691f77cc13f74df37a3512340e05bc8b12ed0837e0` — コンテキスト内の操作、画面幅・入力方式への適応 |
| [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | 2026-10-17 02:36:50 | `a9cf51a0ee6e2d52c49416ad5f9cab423231e27d333615d2bfb1e44d44588522` — ポインタ、キーボード、ウインドウ |

DocC の本文を取得して確認。動画・画像・複雑な表の抽出には制限があるため、その内容からの適合主張は行っていない。2026-10-17 に [Apple Releases](https://developer.apple.com/news/releases/) も確認。実際の検証環境は Xcode **27.1 (27A9275)**、macOS **27.0.1 (26A434)**、iOS Simulator **27.0 (24A5390f)**。最新版情報と検証した OS は区別する。

## 検証記録

ログ・結果は `.build/international-input-20261017/` に保存。ユーザーの Keychain を使わない合成データで検証。

- 単体テスト: 全 201 件成功（Storage 43、Domain 62、Application 96）。国番号・内線・全角/Unicode 数字、全 182 郵便番号正規表現と提供例、発行国と国籍の分離、旧氏名の保存、任意欄の重複防止、電話欄の削除を検証。`final-unit.log`。
- 入力中の遅れたモデル通知が新しい文字列を戻さないよう、単一値・住所・コレクション行で自分の書き込みの反映を追跡する。
- iPhone: 新規 6 ケース（電話、旅券、住所、氏名、拡大日本語、アラビア語）と既存 3 ケース（住所重複、住所の行追加削除、選択肢の追加削除）が、入力速度・スクロール補助の修正後に個別成功。`iphone-final.log` / `iphone-recheck.log` / `iphone-verified.xcresult` に記録。一つの全件成功ランとは区別する。大きな文字では標準の「さらに表示」メニューから保存でき、保存された `middleName` が `Alex` と一致することを確認。
- iPad: 拡大日本語で入力→保存、発行国を米国→日本→フランスへ切り替えて判定と番号保持を確認。`ipad-verified.xcresult` の 2 件成功。国選択シートの検索・タイトル・操作ボタンと、ダーク表示の拡大入力欄を画像で確認。
- iPad の住所: 日本→米国へ国を切り替えると形式判定が更新され、`001-0001` を改変せず保存。保存・キャンセルの表示を画像でも確認。`ipad-sheet-search.xcresult`。
- XCTest の一括文字入力で、入力バインディングに届く前に文字が欠落する現象を検出。文字ごとの入力では氏名・郵便番号の値と保存結果が一致。UI テストのスクロールがキーボード上を操作していた問題も、入力補助バーを避けるよう試験側で修正。高速入力や日本語 IME の品質をこれだけで保証しない。
- macOS: 日本語表示で米国の形式警告→日本の形式一致への切り替え、氏名詳細の任意追加、ミドルネーム・非ラテン文字の入力、保存完了をネイティブ画面と AX で確認。Mac の XCTest はランナー起動後に試験開始できなかったため、GUI 操作で補完。AX 入力は IME の変換試験ではない。Return 単独で編集全体が保存されず、⌘Return では保存されることを確認。自動操作で検索ポップオーバーのキー入力先を維持できなかったため、候補の Return 確定自体は未確認。画像は `artwork/international-input-20261017/mac-passport.png` と `mac-names.png`。
- macOS / iOS のアプリ本体の Debug ビルド成功。iOS は汎用デバイス向け署名なしビルドで、実機のインストール結果ではない。電話・郵便番号メタデータとライセンス通知の同梱を確認。
- 実機、実際の VoiceOver 読み上げ、入力方式すべて、全 12 言語の人手校正、国別の書類種別すべて、番号や住所の実在、iCloud の到着確認は今回の検証対象外。
- この変更はローカル実装。TestFlight に配布済みのビルドと同一だとは扱わない。

代表画像: [Mac の氏名詳細](../artwork/international-input-20261017/mac-names.png)、[iPad の国選択](../artwork/international-input-20261017/ipad-country-search.png)、[iPad の郵便番号判定](../artwork/international-input-20261017/ipad-postal.png)、[iPhone の拡大氏名入力](../artwork/international-input-20261017/iphone-names-large.png)。画像はローカル検証用で、公開用スクリーンショットではない。
