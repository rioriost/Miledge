# 定型項目の入力補助と形式チェック

実装・確認日: 2026-10-17。国・地域別の電話・郵便番号・旅券と氏名構成の改善に続く変更。macOS / iOS / iPadOS の既存編集フォームを使用する。

## 実装した範囲

| 項目 | 入力補助・確認内容 | 確認しない内容 |
| --- | --- | --- |
| メール | メール用キーボード・入力候補、入力例、一般的なローカル部とドメインの構文。入力中は結果を隠し、別の欄へ移った時点で表示 | 配達可能性。Unicode、引用符付きローカル部、ドメインリテラル等は未チェックとして保持 |
| URL | URL用キーボード・入力例。スキーム、HTTP等のホスト・ポート、空白、不完全なパーセント表記を確認。明確なスキーム省略のWebアドレスには「https:// を追加」を提示 | ページの存在・安全性・認証。独自スキームはサービス固有規則を未チェックと表示 |
| クレジットカード | 数字用キーボード、カード番号用のシステム入力候補。一般的な12〜19桁、Luhnチェック。表示用の空白・ハイフンは比較時だけ除去 | 発行元、利用可能性、残高。有効なUnionPay選択時の異なるチェック桁規則は未チェックとして扱う |
| セキュリティコード | 数字用キーボード。既知の3桁ブランドとAmerican Expressの4桁を区別。不明ブランドは3〜4桁 | 発行元への照会 |
| IBAN | 英数字入力。2文字国コード・2桁チェック数字・最大34文字の基本構成、MOD97-10。空白とASCII大小文字を比較用に処理 | 国別BBAN長・銀行コード・口座の存在。結果にもこの制限を明記 |
| BIC | 英数字入力。8文字または11文字、英数字4文字・国コード英字2文字・英数字2文字・任意の支店3文字 | コードの登録・Swiftネットワークへの接続 |
| サーバーポート | 数字用キーボード、1〜65535の入力例と範囲確認。メール受信・送信・データベースごとの標準Menuから候補を選択 | サーバーへの接続、TLS設定の変更。候補は既定値の例であり、プロバイダー指定値を優先 |
| VIN | 英数字入力。現行の17文字とI/O/Q除外。登録国がUS/USAのときのみ9文字目のチェック桁も確認 | 車両の存在、全世界の車台番号規則。旧式・地域固有の番号の例外を案内 |
| OTPシード | 英数字入力。Base32の文字集合・長さ・パディング・未使用ビット。otpauth URL全体との取り違えを案内 | OTPの発行・認証、サービス独自のシード表現 |
| 日付 | 既存のネイティブカレンダー・年月入力を維持。発行日／開始日／生年月日と有効期限、契約開始と終了、保証開始と終了、開始と更新日の前後関係を確認 | 期限切れだけを入力ミスとは扱わない。契約の有効性や法的判断は行わない |

- 明示的なフィールド種別（email / url / otp-seed）、または元の種別・ラベルを保った既知のテンプレート項目だけに適用する。同じ表示名の独自フィールドへ番号規則を推測適用しない。
- 国別情報がない通常の口座番号・ルーティング番号、免許・会員番号、各社のライセンスキー、契約番号、クラウド資格情報、ウォレットアドレス、ホスト名や接続文字列などは自由入力を維持する。形式を一意に決められない項目を一律の正規表現で拒否しない。
- 判定は端末内で完結する。入力値の外部送信・DNS照会・カードや銀行口座への照会は行わない。
- 原文をそのまま保存する。入力補助が値を変えるのは明示的に選択した項目のみ。秘密値を判定文言・ログ・アクセシビリティ説明に埋め込まない。
- 状態は記号と文章で区別し、警告は保存を妨げない。未入力は引き続き任意。既存の構造・日付・数値の保存制約は変更しない。
- 24件の新しいラベル・説明・判定メッセージを既存12言語に追加。国際化ドメインとIPv6をURLで扱う。識別子のASCII大小文字比較でUnicode文字の拡張変換を行わない。
- メール欄のフォーカスを標準のSwiftUI / AppKitの編集通知で追跡する。macOSのTab/Shift-Tab、⌘Return保存を維持。編集ツールバーは標準フォントを指定し、アプリ独自の文字拡大倍率でボタンが切れないようにする。
- 最低対応OS、Schema 1、テンプレート版、Keychain保存・同期方式は変更しない。新しい外部依存も追加しない。

## 一次資料と設計判断

HIGの推奨と、規格上の入力形式・SDK APIは別の根拠として扱う。取得日はいずれも2026-10-17。

| 資料 | 採用した範囲 |
| --- | --- |
| [Apple HIG: Entering data](https://developer.apple.com/design/human-interface-guidelines/entering-data) | 入力負担を減らす候補、入力例、文脈に沿ったフィードバック。04:37:26 UTC取得、SHA-256 `72db13f9ccb322585c1ed03f9dff57126844e3ade47e86a5c1f9972f7d5f4f37` |
| [Apple HIG: Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields) | 入力用途に適したキーボードとラベル。メールは欄を離れた時点の検証が適切という記述を採用。04:37:27 UTC取得、SHA-256 `a0b575085d2380e038d4b610e51d0fac341896dea802e5b2c4c86270701a3ccc` |
| [UITextContentType](https://developer.apple.com/documentation/uikit/uitextcontenttype), [UIKeyboardType](https://developer.apple.com/documentation/uikit/uikeyboardtype) | システムのメール・URL・カード番号入力候補とキーボード。SDK APIの根拠でありHIGの必須要件ではない |
| [RFC 5322](https://datatracker.ietf.org/doc/html/rfc5322), [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986) | メールのdot-atom、引用符等の例外、URIのスキーム・ホスト・エスケープ。完全なRFC適合判定とは扱わない |
| [Stripe card validator](https://github.com/stripe/stripe-ios/blob/master/StripePayments/StripePayments/Source/Helpers/STPCardValidator.swift), [Stripe test data](https://docs.stripe.com/testing?numbers-or-method-or-token=tokens) | カードチェック桁の実装例と公開テスト番号。発行元の実在を断定するためには使用しない |
| [Swift IBAN Registry](https://www.swift.com/swift-resource/9606/download), [TCMB IBAN communique](https://tcmb.gov.tr/wps/wcm/connect/EN/TCMB%2BEN/Bottom%2BMenu/IBAN/Communique) | 最新掲載Release 103（2026-09-17）を参照。基本構造とMOD97-10。国別の完全なレジストリを同梱したとは扱わない |
| [Swift BIC](https://www.swift.com/standards/data-standards/bic-business-identifier-code) | 8/11文字の構成。先頭4文字は英数字を認める |
| [IANA service names and port numbers](https://www.iana.org/assignments/service-names-port-numbers), [PostgreSQL protocol](https://www.postgresql.org/docs/current/protocol.htm) | サーバーポート候補。任意ポートを指定できる自由入力を併設 |
| [49 CFR 565.15](https://www.ecfr.gov/current/title-49/subtitle-B/chapter-V/part-565/subpart-B/section-565.15) | 米国VINのチェック桁、重み、公開計算例。米国以外へこの検査を一律適用しない |
| [RFC 4648](https://www.rfc-editor.org/rfc/rfc4648) | Base32文字集合、末尾のパディング、未使用ビット |

プラットフォームとアクセシビリティの同日確認済み一次資料は、[直前の検証記録](international-input-2026-10-17.md)の取得日時・ハッシュを再利用。アプリ全体のHIG適合認証、App Review提出可否、全世界の識別子の網羅を主張しない。

## 検証

環境: Xcode 27.1 (27A9275)、macOS 27.0.1 (26A434)、iOS Simulator 27.0 (24A5390f)。iPhone 17 Pro、iPad Pro 13-inch (M5)。公開テスト番号とexample.com、合成人名だけを使用。InteractionHostはユーザーのKeychainにアクセスしない。

- **成功:** Swift単体テスト212件。全角・Unicodeや引用符などの未チェック例、境界値、チェック桁違い、未知の独自フィールド、無変更保存、日付の前後関係を含む。
- **成功:** パッケージのカバレッジゲート。2,961 / 3,042実行可能行、14ファイル、**97.33%**。`coverage-final.log` / `coverage-final.json`。これはApp/のUIカバレッジを含まない。
- **成功:** macOSの日本語ネイティブ画面でURL補完、ポートメニュー選択、メール入力→Shift-Tabで判定、⌘Return保存を実行。視覚・AXで入力枠、判定文、フォーカス、保存値を確認。
- **成功:** iPhoneの6種類の新規UI試験（URL/ポート選択と範囲外値の保存、秘密カード、日付、メールのフォーカス、日本語の拡大文字、アラビア語）と既存電話チェックの回帰試験。`iphone-verified.xcresult`ではメール以外の6件成功、メールとツールバー修正後の拡大文字は`iphone-focused.xcresult`の2件成功。単一実行の全件成功とは区別する。
- **成功:** iPadの3件（URL/ポート、メールフォーカス、日本語拡大文字）を`ipad.xcresult`で確認。ネイティブMenu、数字キーボード、保存された原文を検証。
- **成功:** アラビア語のiPhone画面で要素検出・操作領域・ラベル・特性の自動アクセシビリティ監査。VoiceOverの読み上げ試験ではない。
- **成功:** macOSとiOSのアプリ本体Debugビルド。`mac-app-final.log` / `ios-app-final.log`。iOSは汎用デバイス向け署名なしビルドで、実機インストールや配信の確認ではない。
- **視覚確認:** Macの日本語入力欄、iPhoneの秘密カード・アラビア語・ポート候補と数字キーボード、拡大日本語のIBAN警告とツールバー、iPadの入力補助と拡大文字を画像で確認。警告文は折り返し、記号でも区別できる。最大アプリ文字設定とAX3を組み合わせた画面は縦スクロールを要するが保存できる。
- **既存の不一致:** 配布ツール等のPython検査210件中207件成功。README.md / README.ja.md / PRIVACY.mdの3件は、既存文書がbuild 2のままでproject.ymlのbuild 5と不一致。今回これらの文書やビルド番号は変更していない。`tooling.log`。

ログ・xcresultは `.build/format-input-20261017/`。Mac/iPhoneの代表画像は `artwork/format-input-20261017/`。途中の失敗ログも残し、最終結果と区別する。初期の空Viewへの遅延タスクでMacの判定が出ない問題は解消し、メールのみフォーカスに基づく表示へ変更した。iPhoneの自動試験がキーボードに重なった入力欄をタップした問題は、試験側で入力欄の可視範囲を確認するよう修正した。

実機・実際のVoiceOver読み上げ・全12言語の人手校正・高速入力や全IME・実際のシステム自動入力候補・iCloud到着確認・全ての国別番号規則は未検証。番号の実在・有効性は本機能の対象外。TestFlightへの配信は今回行っていない。

代表画像: [Mac入力補助](../artwork/format-input-20261017/mac-server.png)、[iPhone数字キーボード](../artwork/format-input-20261017/iphone-port-keyboard.png)、[iPhone拡大日本語](../artwork/format-input-20261017/iphone-bank-large-final.png)、[iPad入力補助](../artwork/format-input-20261017/ipad-server.png)、[iPad拡大日本語](../artwork/format-input-20261017/ipad-bank-large.png)。ローカル検証画像であり、ストア掲載素材ではない。
