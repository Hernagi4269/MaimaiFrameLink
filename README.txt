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
