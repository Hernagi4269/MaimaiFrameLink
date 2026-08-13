Maimai Frame Link
=================

目的
----
三脚に固定したサブiPhoneでmaimaiを1080p/60fps撮影し、同じローカルネットワーク上のメインiPhoneから動画をコピーせず確認するためのアプリです。
同じアプリを2台に入れ、撮影側（Camera）と確認側（Viewer）を選びます。

Windowsのみ・無料で使う構成
----------------------------
1. GitHubへこのフォルダを1つのリポジトリとして置く。
2. GitHub ActionsがmacOSランナー上で未署名の MaimaiFrameLink.ipa を生成する。
3. WindowsへIPAをダウンロードする。
4. Windows版SideloadlyでIPAを各iPhoneへインストールする。
5. 無料Apple Accountの署名は7日で失効するため、期限後は同じIPAを再署名・再インストールする。

GitHub Actions
--------------
.github/workflows/build-ios.yml がビルド定義です。
mainブランチへのpush時、またはActions画面のRun workflowから実行できます。
生成物はActionsのArtifactsに MaimaiFrameLink として出力されます。

無料運用上の注意
----------------
・GitHub Actionsはpublic repositoryの標準runnerなら無料です。ソースを公開したくない場合、private repositoryにも無料枠はありますがmacOS runnerは消費倍率が高いため、頻繁なビルドでは枠を使い切る可能性があります。
・SideloadlyはWindowsで利用できます。
・無料Apple Accountのアプリ署名は7日で失効します。継続利用には再署名・再インストールが必要です。
・2台のiPhoneは無料Apple Accountのテスト端末上限（3台/7日）の範囲内です。

現状の主要機能
--------------
・同一アプリ内でCamera / Viewerを切替
・背面カメラによる1080p/60fps優先録画
・動画原本はCamera側端末に保存
・BonjourによるCamera端末の検出
・HTTP Range対応ローカル動画配信
・Viewer側でコピーせずAVPlayer再生
・シーク
・-10F / -1F / +1F / +10F
・最新録画の自動検出

最優先の実機検証
----------------
1. iPhone実機でビルド済みIPAが起動すること
2. 1080p/60fpsで実際に録画されること
3. 2台間でBonjour検出できること
4. 録画停止後、Viewerに最新動画が自動反映されること
5. ネットワーク越しの±1Fが実用速度で動くこと

開発ファイル運用
----------------
バージョンごとの差分ファイルや旧版を増やさず、原則としてこの同一構成を更新します。
