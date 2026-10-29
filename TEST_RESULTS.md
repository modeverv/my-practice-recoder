# 検証結果 — 2026-10-29

## v1.1.1：実行中のDockアイコン修正

`AppDelegate.applicationDidFinishLaunching`でbundle内のicnsを直接読み、`NSApp.applicationIconImage`とDockタイルへ反映するよう修正。`./scripts/build-app.sh`によるrelease build・署名検査成功（`Validation/v1.1.1/build.log`）。ユーザーからDockの新アイコンが表示できている旨の報告があり、追加の画面確認は不要との指示で終了した。今回の変更は起動時の画像設定だけで、録画処理は変更していない。自動テスト一式の再実行は行っていない。

## v1.1.0：アイコン・自動同期モードの追加

- `PRACTICE_RECORDER_HARDWARE_TEST=1 ./scripts/test.sh`: **50 tests / 0 failures / skipなし**。
- `./scripts/build-app.sh`: release arm64 / アイコン生成・同梱 / ad-hoc署名と検査成功。
- 新規アイコンを1024px原画から16〜1024pxのicnsへ生成。NSWorkspaceが実際の.appに対して返すアイコンも抽出・目視確認済み。`Validation/v1.1/bundle-icon.png`。
- カメラ・RME11/12・画質設定を保持して起動し、実入力確定後に「自動同期（共通PTS）適用済み・追加補正0ms」を自動表示することをGUIで確認。
- 自動モードは保存済み手動値を変更せず適用値のみ0ms。旧設定JSONに新しいキーがなくても、カメラ・音声ID・11/12・楽器・保存先・手動値を保持する移行試験が成功。手動モードへ戻すと手動値を再利用できる。
- 共通PTSの実writer回帰試験：video PTS=100秒、audio PTS=100.125秒、旧手動値−240msを与えた自動モードで、共通t0=100秒と本来の125ms差を維持。生成MP4をデコードし冒頭無音／以後の音声を検査。ストリームごとの独立ゼロ起点化や、到着差の補正値への流用は行っていない。
- 入力変更・入力断は適用状態を無効化。録画直前に有効な設定からplanを確定し、不変のRecordingRequestへ渡す。録画中のモード・補正変更は不可。別エージェントの読み取りレビューでも重大指摘なし。
- 再署名後は前回と同様にPractice Recorderだけのカメラ許可をOFF→ONし、OSの「終了して再度開く」で反映。マイクや他アプリの権限、RME/TotalMixは変更していない。
- v1.1の実GUI録画：ユーザー設定のeMeet C960 / 1080p30 / RME11/12で自動同期適用表示→⌘R開始→⌘R停止→通常名保存を確認。`guitar-2026-10-29-140413-00m29s-9a17e54c.mp4` のトラック／全音声デコード結果は `Validation/v1.1/gui-output.log`。設定を再適用しても自動同期済みへ戻ることを確認し、待機状態にした。
- ログは `Validation/v1.1/`。初回v1.0時の実5分記録を以下に保存している。v1.1では実5分を繰り返さず、300秒境界の自動テストを再実行した。

ユーザーの確認により、今回の「自動同期」は**クラップなしの共通PTS方式**。物理的なカメラ遅延、Liveエフェクト等を含む実遅延の自動校正は追加していない。この点を設定画面とREADMEにも明記した。

## 以下は初回v1.0の検証記録

## 環境・成果物

- 実機: MacBook Pro / Apple M4 Max / 128GB。
- macOS 27.0.1 (26A434)、Xcode 26.6 (17F113)、Apple Swift 6.3.3、SDK 26.5。
- Swift言語モード5、arm64、最低macOS 15.0。Mach-OのLC_BUILD_VERSIONもminos 15.0を確認。macOS 15実機での起動は未実施。
- `build/Practice Recorder.app` を生成、ad-hoc / hardened runtime署名、`codesign --verify --strict`成功、Info.plist検査成功。外部依存のインストールなし。
- 既存のHANDOFFとSTART-PROMPTは変更せず、新規Swift Packageを構築した。

## 実行コマンドと結果

| コマンド | 実行結果 |
|---|---|
| `swift scripts/device-probe.swift` | 同じAVCaptureSessionからHP HD Camera映像とRME native 48kHz/20ch/Float32 planarを実取得 |
| `PRACTICE_RECORDER_HARDWARE_TEST=1 ./scripts/test.sh` | **42 tests、0 failures、skipなし**（最終ソース） |
| `./scripts/build-app.sh` | release arm64実行ファイルと署名済.app生成成功（最終ソース） |
| `codesign --verify --strict --verbose=2 'build/Practice Recorder.app'` | valid on disk / satisfies Designated Requirement |
| `xcrun vtool -show-build …/PracticeRecorder` | minos 15.0 / sdk 26.5 |
| `swift run PracticeRecorderCheck --camera 0x2242100004ca7089 --audio RMEUSBDevice-130-24100500 --left 11 --right 12 --seconds 6` | 6.267秒のHEVC/AAC MP4を生成・検証・非上書きrename成功 |
| `./scripts/inspect-output.sh FILE.mp4` | 実機短時間／実5分のトラック・終端・codec・全音声デコード検査成功 |
| `swift scripts/audio-state.swift` の開始前後diff | RME rate/bufferとデフォルト入出力の差なし |

ログは [Validation/](Validation/) に保存。`tests.log`、`build.log`、`signature.log`、`macho-build-version.log`、`audio-before.json`、`audio-after.json`、実出力の検査ログを参照。通常の `./scripts/test.sh` では明示的実機テスト2件をskipする。上記42件実行では両方実行した。合成writer試験もこのMacのハードウェアHEVC経路で成功し、ソフトウェアへ切り替えた合格はない。

## 実機で確認したこと

- RME Fireface UCX II入力は48,000Hz、20ch、Float32。任意入力Ch11/12を0始まり10/11へ変換し、選択ステレオ48kHz/Float32としてPTSを維持して取得。選択L/Rメーターは実信号で反応した。
- Liveプロセスが実行中で、ユーザーが再生中と申告した環境で録画。RMEは48kHz / 512frames、macOSデフォルト入出力はSOUNDPEATS Spaceのまま。Live・TotalMixを操作せず、アプリにも音声出力はない。
- HP HD Camera 720p30設定で取得し、HP720p→MacBook1080p→HP720pの実再設定も成功。最終アプリはユーザー選択のMacBook Proカメラ / 1080p30 / RME11/12を復元している。
- .appの日本語画面、縦横比維持プレビュー、L/Rメーター、経過時間、録画中の設定／楽器変更禁止、手動開始停止、⌘R開始、再起動後の設定復元をGUIで確認。録画は自動開始しない。
- QuickTime Playerで手動停止ファイルを開き、映像描画・再生開始とインスペクタのHEVC/AAC/48kHzを確認。エージェントが実際の音を聴いたという判定はしていない。

### 手動停止ファイル

`~/Movies/PracticeRecorder/guitar/2026/10/guitar-2026-10-29-133233-00m13s-63a449a2.mp4`

- 実測尺12.568145833秒、命名は最近秒へ丸めた00m13s。
- HEVC 1920×1080、平均29.996012fps、映像終端12.535秒。
- AAC、音声終端12.568145833秒。
- 全音声をPCMへデコード成功。RMS 0.007110887、peak 0.101932324。

### 実時間5分・最小化試験

`~/Movies/PracticeRecorder/guitar/2026/10/guitar-2026-10-29-133249-05m00s-55f5b21c.mp4`

- ⌘Rで開始後、最初の約10秒でウィンドウを最小化。保存後まで最小化したまま継続した。
- **asset duration = 300.0秒、映像終端 = 300.0秒、音声終端 = 299.9999791667秒**。
- HEVC 1920×1080、平均29.996666fps、AAC。全音声PCMデコード成功（28,799,998個のinterleaved Float値、RMS 0.007088009、peak 0.101932324）。
- 完成名1本へ確定し、partialは残らなかった。復帰時は保存完了表示・待機状態で、次の録画は始まらなかった。
- 録画4:48時点に本アプリのidle sleep assertionが存在し、保存後は解除されていた。
- この連続試験後、原入力／補正後PTSの二重トリム、検証誤差の厳格化、等価PCM packing切替判定を修正した。最終ソースでは42件を再実行し、実機再設定と実HEVC writer境界も再確認。最終.appでも短時間の終了時保存を別途試験した。

### 最終.appの録画中終了試験

`~/Movies/PracticeRecorder/guitar/2026/10/guitar-2026-10-29-134454-01m02s-c012be01-interrupted.mp4`

録画中の⌘Qで停止・保存を試み、実測62.436833333秒のHEVC/AACファイルをinterrupted名で確定してからアプリが終了した。partial、実行プロセス、本アプリのsleep assertionが残っていないことを確認。全音声デコードとトラック検査結果は `Validation/gui-exit-output.log`。その後に再起動し、設定復元・待機状態への復帰も確認した。テスト3本は保存先に残してあり、自動削除していない。

HPの初期6秒診断ファイルは設定30fpsに対して実出力平均約14.92fpsだった。フレーム複製は行っていない。MacBookカメラの上記ファイルでは実出力約29.997fpsを確認。カメラの設定レートと実際に届くフレーム数は区別する。

## 合成・異常経路の検証範囲

- 20chの離れた任意L/R、左右反転、1/0始まり、interleaved／planar／複数ch grouped ABL、Float32/64、signed Int16/24/32、endianness、44.1/48kHz、無効index、無音、借用メモリ寿命。
- 正負offsetの開始前・上限後PCM切り詰め。元入力PTSと補正後PTSの両方に境界を適用。CMTimeの分数演算と1tick丸めの回帰試験。
- +100ms／−100msの**生成MP4をAVAssetReaderでデコード**して冒頭無音／音声開始を比較。AACがleading gapをtrack start=0の無音として表現することも確認。
- 300秒の疎な合成入力によるwriter／各track終端検査。疎な音声にはPTS不連続があり、異常終了結果とする試験である。実5分試験とは別。
- 32並列stopでもfinish callbackが1回。arming停止、開始連打、保存中の再開始禁止、古いrecording ID、手動／timeout／入力断stopの重複を検証。
- 偽単調時計299.9→300→300.1、表示更新・壁時計に依存しない期限計算、古いtimerの排除。
- 音声未到着3秒timeout、未知device／camera、96kHz拒否、保存先がファイルの場合の失敗、無効MP4のpartial保持、既存名との衝突と非上書きrename、開始年月・タイムゾーン固定。
- 保存検証のtimeoutが返った後に遅れた検証がrenameを開始しないこと、完了通知1回、60fps/30fps/29.97fpsで1映像frameまたは1AACframe以内の許容境界。

## レビューと修正

親が共有型・queue契約・状態機械の骨格を先に作り、A:Capture/PCM、B:Writer/PTS、C:UI/設定/保存に重複しないファイルを割当てて実装した。統合後にA/Cをレビュー専任へ切り替え、BもCaptureをレビューした。

レビュー／実機テストで修正した主な問題は、正offsetで映像まで早期終了すること、旧capture output callbackの混入、入力断後の誤ready、未適用設定と実入力の不一致、保存検証の無期限待ち、開始タイムゾーン未固定、借用PCM block寿命、音声PTS不連続、初期native PCMの等価packing切替の誤判定。失敗した実機テストを合格扱いせず、修正後の最終実行をログに残した。

再署名直後、システム設定でカメラ許可ONにもかかわらず新バイナリが未許可になる状態が実際に発生。**Practice Recorder自身のカメラ許可だけをOFF→ONし「終了して再度開く」**で解消した。他アプリの権限、マイクの既存許可、RME/TotalMix設定は変更していない。全体のtccutil resetは使用していない。

## 未確認・制約

- 冒頭／末尾の同じクラップによる実A/V固定ずれ・ドリフトの測定は未実施。「音ズレゼロ」「1frame以内」とは判定していない。
- 物理RMEの44.1kHz、1080p60、eMeet C960を使った録画は未実施。44.1kHzは合成試験で検証済み。
- TotalMixサブミックスに混ざる音の内容／他chの実機信号分離、Liveの聴感上の継続はエージェント未確認。抽出ロジックの任意ch分離と実11/12の信号取得は確認済み。
- 実デバイスの物理抜去、容量枯渇、外付け切断、明示的スリープ、電源断、OS強制終了は未実施。通常エラー経路・timeoutは自動試験済み。
- 権限拒否を意図的に再現するための権限resetはしていない。再署名後の未許可状態ではクラッシュせず設定案内が出ることを確認。
- OSのI/O syscall開始後の取消しや、強制終了した非fragmented MP4の修復は保証しない。
