# Microsoft Teams 通知モニター

Microsoft Graph を使って Teams の未読メッセージと自分宛てのメンションを確認し、音と ntfy 通知で知らせる Windows 用 PowerShell スクリプトです。

## できること

- 起動時に 1 対 1 チャットの未読受信メッセージを確認
- 起動後に届いた 1 対 1 / グループチャットの自分宛てメンションを検出
- 未読の間、設定した間隔で音を鳴らす
- 起動時と検出時に ntfy トピックへ通知
- Microsoft Graph のサインインにデバイスコード認証を使用

起動時点ですでに存在するメンションは基準として記録し、新着通知の対象にはしません。

## 必要なもの

- Windows と Windows PowerShell
- Microsoft 365 / Teams アカウントと、Microsoft Graph `User.Read` および `Chat.Read` スコープへのアクセス
- `Microsoft.Graph.Authentication` PowerShell モジュール
- ntfy トピック名

Graph の利用可否や必要な同意は組織の設定によって異なります。職場アカウントでの利用前に、組織のポリシーを確認してください。

## セットアップ

1. このフォルダーをローカルに配置します。
2. `setting.txt` を作成し、次のように設定します。値は説明用の例です。

   ```text
   topicname = example-teams-alerts
   pcname = PC-1
   ```

   `topicname` は通知先の ntfy トピック名です。実際に使う場合は、自分で管理する一意で推測されにくいトピック名に変更してください。`pcname` は通知に表示する端末名です。`topicname` は半角英数字、`_`、`-` を使い、1〜64文字で指定します。

3. PowerShell で Graph 認証モジュールをインストールします（未導入の場合）。

   ```powershell
   Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
   ```

4. `notice.wav` がフォルダー内にあることを確認します。通知音を使わない場合も、スクリプトはファイルがないことを表示して監視を続けます。
5. `起動.bat` を実行します。初回は表示された案内に従って、ブラウザーで Microsoft のデバイスコード認証を完了します。

## 起動と停止

`起動.bat` は `TeamsMentionMonitor.ps1` を30秒間隔で実行します。停止するにはコンソールで `Ctrl+C` を押します。

監視間隔を変更するには、`起動.bat` の `-IntervalSeconds 30` の数値を秒単位で変更します。

## ファイル

| ファイル | 用途 |
| --- | --- |
| `TeamsMentionMonitor.ps1` | Graph を使ったチャット監視と通知 |
| `GraphSignInWindow.ps1` | デバイスコード認証ページを開く案内ウィンドウ |
| `setting.txt` | ntfy トピック名と通知に表示する端末名 |
| `notice.wav` | 通知音 |
| `起動.bat` | 監視スクリプトの起動 |
| `keepaudio.ps1` | 30秒ごとに Windows のビープ音を鳴らす単独スクリプト |
| `Microsoft-sign-in.url` | Microsoft サインインページへのショートカット |
| `画面1枚.bat` / `画面2枚.bat` | このREADMEからは用途を確認できない補助バッチファイル |

## 通知について

通知は ntfy.sh の指定トピックへ送られます。トピック名を知っている人が通知を受け取れる可能性があるため、公開場所や共有先に実際のトピック名を含む `setting.txt` を置かないでください。このREADMEには例示用の値だけを記載しています。

## ライセンス

このソフトウェアは MIT License の下で公開されています。詳細は [LICENSE](LICENSE) を参照してください。

