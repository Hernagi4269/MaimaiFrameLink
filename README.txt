Maimai Frame Link

目的
- サブiPhoneを三脚に固定したまま1080p/60fpsで撮影する。
- 撮影動画の原本は撮影側iPhoneだけに保存する。
- 確認側iPhoneからクラウド同期や手動転送なしで最新動画を再生・シーク・±1F/±10F確認する。

構成
- 同じアプリを2台へインストールし、初回に「撮影側」「確認側」を選択する。
- 撮影側はBonjour + ローカルHTTP Range配信を行う。
- 通常Wi-Fiに加え、Apple peer-to-peer Wi-Fiを有効にして2台を直接発見できるようにしている。
- 動画はH.264 / 1080p / 60fpsを優先する。

v0.2.0
- 1080p/60fpsフォーマット選択を見直し、120/240fps向けスローモーション形式を誤選択しないよう修正。
- HDRと自動低照度フレームレート切替を抑制し、露出・WB・AFは連続自動制御を維持。
- Bonjour共有をpeer-to-peer対応にし、DefunctConnection等でListenerが落ちた場合の自動再起動を追加。
- 確認側のBonjour探索もpeer-to-peer対応。
- カメラ＋リズムリングをモチーフにした専用App Iconを追加。

Windowsのみ・無料でのビルド
1. このフォルダの内容をGitHubリポジトリのルートへ置く。
2. .github/workflows/build-ios.yml がGitHub Actionsで実行される。
3. 成功後、ArtifactのMaimaiFrameLink.zipからMaimaiFrameLink.ipaを取得する。
4. Windows版SideloadlyでiPhoneへインストールする。

注意
- 無料Apple Accountでのサイドロードは署名期限の制約がある。
- 60fpsの実動作、室内照明でのフリッカー、P2P接続速度、フレーム送りのレスポンスは実機で最終確認する。

【v0.4.0 手動撮影方向】
撮影側は端末の自動回転に追従しません。撮影画面上部の「縦 ↑ / 縦 ↓ / 横 ← / 横 →」から撮影方向を明示的に選択します。
矢印は完成動画の「上」にしたい方向を示します。選択した方向は保存され、次回起動時も維持されます。録画中は方向変更できません。

【Sideloadly 自動再署名（Windows）】
1. PCとiPhoneを同じネットワークに接続します。
2. 最初だけUSB接続し、iTunesの端末画面 > 概要 > オプション > 「Wi-Fi経由でこのiPhoneと同期」を有効にして同期します。
3. SideloadlyでIPAを入れる際にAutomatic App Refresh（自動更新）を有効にします。
4. 以後はSideloadly DaemonがPCで動作し、iPhoneをWi-FiまたはUSBで検出できた際に期限が近いアプリを自動再署名します。
5. アプリ更新時も同じApple ID・同じBundle IDのまま、新しいIPAをAutomatic App Refresh有効で上書きインストールします。


撮影方向UI
- 画面全体やシャッターボタンは撮影方向の指定では回転しません。
- 「縦 / 横」で動画の向きを選択し、「180°」でその向きを反転します。
- 撮影方向の指定はカメラプレビューと録画動画にのみ適用します。
- 録画中は誤操作防止のため方向変更を無効化します。

v0.5 planned improvements integrated:
- Landscape capture UI reduced; shutter fixed on the right edge like Camera.app.
- Viewer can start/stop recording on the capture iPhone.
- Viewer reload button re-runs discovery and refreshes the newest video.
- Offline peer-to-peer discovery retry strengthened (Wi-Fi/Bluetooth must remain enabled).
- Trim: mark start/end at the current frame and save a new trimmed copy to Photos; source remains untouched.
- Imported local videos remain deferred.
