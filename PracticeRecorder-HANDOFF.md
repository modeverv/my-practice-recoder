# Practice Recorder — 実装ハンドオフ

更新日：2026-10-29  
対象：6.1sol / Codex 等の、ローカルリポジトリを編集・ビルドできる実装エージェント  
成果物：macOS用の、実際に起動・録画できる小さなネイティブアプリ

> この文書は実装依頼である。設計提案だけで終わらず、コード、起動可能なアプリ、テスト、セットアップ手順まで仕上げる。既存リポジトリの指示とユーザーの変更を尊重する。実機・権限がなく確認できなかった項目は、成功したと報告しない。

## 1. 作るもの・作らないもの

**楽器を選び、ボタンを押すと、Webカメラ映像とRME Loopback音声を最大5分録画し、自動命名したMP4を保存するアプリ。**

ユーザーはM4 MaxのMacを使い、複数の楽器を日々練習する。Webカメラは部屋のスタンドに設置済みで、約10mのケーブル経路で接続されている。音楽制作環境はAbleton LiveとRME Fireface UCX II / TotalMix FX。具体的なカメラ機種、空いているRME入出力ペア、実際のサンプルレートは未確定なので、検出・選択する。

音声の経路は次に固定する。

```text
楽器 → RME → Ableton Live（モニター・エフェクト・伴奏など）
                    ↓
              RME Software Playback
                    ↓
      TotalMixの録画用サブミックス / Loopback
                    ↓
       アプリで選んだRME入力L/R → 録画ファイル

Webカメラ → プレビュー + 録画ファイル
```

アプリはLiveやTotalMixを制御しない。「Liveのプロセス音声を直接取得する」のではなく、ユーザーがTotalMixで構成したLoopback入力を録音する。

**対象外：** OBS、FFmpeg等の録画用外部プロセス、Core Audio Process Tap、ScreenCaptureKit、BlackHole、SMPTE/MTC/LTC、MIDI/OSC、Live API連携、編集、再生プレイヤー、履歴DB、一覧ライブラリ、サムネイル生成、クラウド同期、NAS転送、音声モニター出力、AI分析、連続分割録画、自動再録画。

録画ファイル以外に保存してよいものは、アプリ設定と必要最小限の診断ログ。録画ごとのJSONやSQLiteインデックスは作らない。履歴管理はFinderなどのファイルシステムに任せる。

## 2. MVPの確定仕様

| 項目 | 仕様 |
|---|---|
| UI | SwiftUI、通常の1ウィンドウ。日本語表示 |
| 対象 | Apple Silicon / M4 Max。新規なら最低macOS 15.0を採用 |
| 映像 | macOSから利用できるWebカメラ1台。デバイス選択を保存 |
| プレビュー | 待機中・録画中とも表示。縦横比維持、初期状態は非ミラー |
| 音声 | 選択したRMEデバイスの任意の入力2chを、L/Rとして録音 |
| 楽器 | Guitar / Bass / Drums / Piano / Other。分類用でありルーティングは変えない |
| 操作 | 楽器選択 → 大きい「録画開始」。録画中は「停止して保存」 |
| 上限 | **1回300秒。到達時に自動停止・保存。次の録画は開始しない** |
| 時間表示 | 大きい `REC 02:17 / 05:00`。待機中は `00:00 / 05:00` |
| 音声表示 | 選択済みL/Rのピークメーター。無音と入力断を区別 |
| 保存 | HEVC + AACステレオ / MP4。圧縮は録画時に行う |
| 初期画質 | 1920×1080 / 30fps / 映像目標3Mbps / AAC 192kbps |
| 追加画質 | 1080p60 / 5Mbps、720p30 / 1.5Mbps。カメラ対応時のみ |
| 設定 | 保存先、カメラ、音声デバイス、L/Rチャンネル、画質、A/V補正値 |
| 保存確認 | 保存完了メッセージと「保存フォルダーをFinderで開く」 |

画質値は初期設定であり、画質や厳密なファイルサイズの保証値ではない。カメラが対応しない解像度/FPSを、フレーム複製やアップスケールで見せかけて実装しない。対応候補から選べるようにし、実際の設定を表示する。29.97/59.94等も実際の分数レートとして扱い、時刻を30/60に丸め直さない。

楽器ボタンは分類の選択だけ。録画ボタンを兼ねさせない。直前の楽器を記憶するため、通常は録画ボタン1回で開始できる。録画中・保存中は楽器、デバイス、保存先、画質を変更できない。

アプリ内に履歴画面は作らない。保存直後の通知や、そのセッション内だけの保存先表示は構わないが、終了後まで最近使ったファイル一覧を保持しない。

## 3. UIの目安

```text
┌──────────────────────────────────────────────────┐
│ Practice Recorder                         設定…  │
│                                                  │
│               カメラプレビュー                   │
│                                                  │
│ [Guitar] [Bass] [Drums] [Piano] [Other]             │
│ RME UCX II  入力L: Ch xx  R: Ch yy                 │
│ L ███████░░░    R ██████░░░░                      │
│                                                  │
│                REC 02:17 / 05:00                  │
│                 [ 停止して保存 ]                  │
│                                                  │
│ 1080p30 / HEVC    [保存フォルダーを開く]            │
└──────────────────────────────────────────────────┘
```

「準備中」「録画中」「保存中」「エラー」を文字でも区別する。色だけに依存しない。時間は等幅数字。開始・停止音、保存完了音をアプリから鳴らさない。録音への混入を避ける。

キーボード操作はアプリにフォーカスがある時の `⌘R` で開始/停止する。グローバルホットキー、アクセシビリティ権限、Input Monitoring権限は不要。Liveの操作を奪わない。

## 4. 実装構成：標準APIで小さく作る

### 4.1 第一選択

**映像と音声を同じ `AVCaptureSession` で取得する。**

```text
AVCaptureDeviceInput（カメラ） ─→ AVCaptureVideoDataOutput ─┐
       └→ AVCaptureVideoPreviewLayer                      │
                                                         ├→ AVAssetWriter → MP4
AVCaptureDeviceInput（RME） ─→ AVCaptureAudioDataOutput     │
       └→ 指定L/Rだけ抽出 → ステレオPCM ──────────────────┘
```

Appleはcapture sessionの出力を同期する時計を提供している。[A1] 独立した音声エンジンと映像エンジンを最初から作って、時計の同期問題を増やさない。

音声側の `AVCaptureAudioDataOutput.audioSettings = nil` はデバイスのネイティブ形式での出力を指定する。[A2] この設定から開始し、**実際に届くASBD、チャンネル数、バッファ構造を検査**する。RMEから必要なチャンネルが取得できていることを初期検証で確認する。

SDKの利用可能なシンボルはローカルで確認する。`synchronizationClock` がdeployment targetで利用できなければ、availability guardと `masterClock` を使用する。新しいAPIを無条件に呼んで最低OSで起動不能にしない。

### 4.2 限定的な代替経路

実機でAVFoundationから必要なRMEチャンネルを取得できないことが判明した場合に限り、音声入力アダプターをCore Audio HAL / AUHALに差し替えてよい。これは最初から並行実装しない。

その場合は実際の入力タイムスタンプのhost timeを使い、Core Mediaの時計変換で映像側の時計に合わせる。コールバック到着時の `Date()` や `mach_absolute_time()` を、入力サンプルの取得時刻の代用品にしない。時刻変換やクロックドリフトが未検証なら、その旨を残す。

**RME実機がない場合、取得できたことを仮定しない。** 第一選択を実装し、合成多チャンネル音声でテストし、実機確認を残課題として具体的に報告する。内蔵マイクへの無断フォールバックで「動作した」ことにしない。

## 5. 音声：多チャンネルの扱いが重要

### 5.1 デバイスとチャンネル選択

UIは入力チャンネルを1始まりで表示し、内部では0始まりへ明示的に変換する。デバイスの永続IDを保存し、列挙順や現在の一時的なAudioDeviceIDだけで保存しない。

L/Rは個別に選択できる。デバイス・ストリーム形式が確定してから、有効な範囲を表示する。取得できるならチャンネル名も添えるが、名前から番号を推測しない。最初の1/2chを勝手に録音対象にしない。初回はLoopback用L/Rの明示選択を必要とする。

**「ステレオで出力」と指定するだけでは任意の2ch選択にはならない。** 全入力の自動ダウンミックスを禁止する。`AVAudioConverter.channelMap` を使用する場合、出力2chに対して `[leftIndex, rightIndex]` を設定する。これは0始まりの入力チャンネルを指定するAPIである。[A3]

生のPCMを自前で抽出する場合も、次を満たす。

- 入力ASBDとAudioBufferListを読み、interleaved / non-interleavedを区別する。
- 「1バッファ=1チャンネル」「常にFloat32」「常に20ch」と決めつけない。
- 対応形式を明確にし、未知の形式は説明付きエラーにする。
- 抽出したPCMのサンプル数、レート、元のPTSを維持する。
- 非同期利用するメモリの寿命を保証し、コールバック終了後の借用ポインターを保持しない。

### 5.2 既存のLive環境を壊さない

アプリはデバイスのサンプルレート、クロック、バッファサイズ、macOSのデフォルト入出力を変更しない。RMEを排他取得しない。TotalMixのルーティングやLoopback ON/OFFを変更しない。

MVPは少なくとも44.1kHzと48kHz入力をサポートする。AACの出力レートもこの2つは入力に合わせる。高レート入力をサポートする場合は、デバイス設定を変えずアプリ内で変換する。未対応なら開始前に明示する。録画中に形式・レートが変わった場合はそのテイクを停止し、保存可能なら保存して警告する。

L/Rメーターは、**ファイルに書くのと同じ選択済み音声**から計算する。表示更新は10〜20Hz程度でよい。無音は有効な音声データであり、無音を理由に開始を拒否しない。一方、入力バッファが届かない場合は録音準備完了にしない。

音声を再生するノード・出力をアプリに作らない。AGC、ノイズ抑制、ゲート、コンプレッサーを追加しない。

## 6. HEVC録画と映像プレビュー

`AVAssetWriter` とvideo/audioのwriter inputでMP4を出力する。各録画で新しいwriterを作る。プレビューは同じcapture sessionの `AVCaptureVideoPreviewLayer` を使い、別カメラセッションを開かない。

HEVCはハードウェアエンコーダーを要求する。`AVVideoEncoderSpecificationKey` はvideo settingsの**トップレベル**に置き、その辞書内で `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` をtrueにする。前者がVideoToolboxのencoder specificationを受け取ること、後者がハードウェア必須の設定であることはAppleの仕様に基づく。[A4][A5]

概念例。周辺の設定値・availability・設定受理は実装環境で検証すること。

```swift
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoEncoderSpecificationKey: [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
    ],
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoAllowFrameReorderingKey: false
    ]
]
```

HEVC設定が受理できない場合、黙ってソフトウェアエンコードやH.264へ変更しない。理由を表示する。`canApply`だけで実際にハードウェアセッションが開けたと断定せず、初期書き込みの失敗も処理する。専用のVTCompressionSessionを追加するのは、この標準経路で要件を満たせない場合だけにする。

writer inputはリアルタイム入力として構成する。カメラから得られる実際の解像度・FPS・pixel formatに合わせる。毎フレームNSImage/PNG/JPEGに変換しない。プレビューに描くRECや時間表示はUIであり、保存映像へ焼き込まない。

SDR / 8bit / 通常の2D映像のみでよい。HDR、ProRes、AV1、マルチカメラは実装しない。完成ファイルをQuickTime Playerで再生して確認する。

## 7. 時刻・5分停止・A/V同期

### 7.1 時刻を3種類に分ける

1. **日時**：ファイル名用。実際に録画が始まった時点のローカル日時を一度だけ取得する。
2. **単調増加時計**：画面の経過時間・停止watchdog用。時刻設定変更の影響を受けない。
3. **メディアPTS**：映像・音声の同期と、保存ファイルの尺を決める。

表示用Timerの発火回数を数えて録画時間にしない。UIが止まっても停止処理が働く構成にする。

### 7.2 開始

`ready → arming → recording → stopping → ready` を基本状態とする。失敗時はエラー状態へ遷移する。状態の所有者は1つだけにする。

開始操作時に楽器、保存先、デバイス、画質、補正値を不変の録画コンテキストへコピーし、そのテイク中は変更しない。最初に両ストリームの有効な形式・サンプルが取得できることを確認する。3秒程度待っても必要な入力が得られない場合は開始失敗にする。無音のPCMは有効。

開始要求後の映像PTSを基準に、共通の録画開始PTS `t0` を確定する。音声・映像を別々にゼロ起点へリセットしない。開始前のサンプルを除外し、開始境界をまたぐPCMは必要に応じて切り詰める。`AVAssetWriter.startSession(atSourceTime:)` と、書き込むサンプルの時間軸を整合させる。[A6]

録画開始が確定した時にREC表示・単調時計の基準・日時を確定する。arming中にファイル名用の「録画尺」を増やさない。

### 7.3 300秒停止は二重で保証する

**A：メディア境界**

```text
recordingEndPTS = t0 + 300 seconds
```

この時刻以降の音声・映像を新たな記録対象にしない。末尾をまたぐPCMを必要に応じてトリムする。映像の最後のdurationとwriterのセッション終了時刻も上限に合わせる。終了後にエンコーダーが処理する、既に受理済みのデータと、新しい録画データを区別する。

**B：単調時計watchdog**

UIのrun loopと独立した停止経路を用意し、300秒到達で同じ停止処理へ入れる。カメラ停止等でPTSが進まない場合も、録画中のまま残さない。通常の入力断は5分を待たず検出・停止する。

自動停止、手動停止、デバイス切断、終了要求はすべて同じ冪等なstop処理へ集約する。手動停止と自動停止が同時に起きても、finish/rename/通知は1回のみ。古い録画のタイマーが次のテイクを止めないようrecording IDを照合し、停止後にタイマーを解除する。

画面は300秒で `05:00 / 05:00` に止まり、その後は「保存中」。保存完了までの時間を録画時間に足さない。保存後は待機状態へ戻り、**連続録画は開始しない**。

仕様上限は300秒。受入検査では、コンテナ・AAC等の表現上の丸めに限り最大1映像フレームまたは1音声圧縮フレーム程度の誤差を許容するが、タイマーの遅延で301秒以上録る実装は不合格。可能な限り提示上の尺を300秒以下に収める。実際のasset durationとトラック終端を検査する。

### 7.4 固定オフセット

詳細設定に `audioOffsetMs` を1つ用意する。初期値0、範囲−500〜+500ms、10ms刻み。

**正値は「映像に対して音声を遅らせる」**とUI・コード・テストで統一する。補正は音声のPTSへ一度だけ適用する。負値でt0より前に出るPCMは切り捨て、正値で開始に空白が出る場合は適切な無音区間として扱う。上限300秒は補正適用後の提示時間軸にも適用する。

固定オフセットは固定的な遅延の補正用であり、時計のドリフトをごまかすものではない。同じcapture sessionでも実機の映像遅延は残り得る。5分の冒頭・末尾で同じクラップ等を確認する手動試験を用意する。検証前に「音ズレゼロ」と宣言しない。

## 8. ファイル名・安全な保存

デフォルト保存先は `~/Movies/PracticeRecorder/`。設定からフォルダーを選べる。日付は開始時点のローカル日時、年月ディレクトリも開始時点基準。

```text
~/Movies/PracticeRecorder/
  guitar/2026/10/
    guitar-2026-10-29-141530-05m00s-7f3a9c2d.mp4
  bass/2026/10/
    bass-2026-10-29-144203-02m17s-0e2d471a.mp4
  drums/2026/10/
  piano/2026/10/
  other/2026/10/
```

形式：

```text
{instrument}-{yyyy-MM-dd}-{HHmmss}-{mm}m{ss}s-{id8}.mp4
```

instrumentは固定slug。`id8` は衝突防止用の短い識別子で、実際に衝突した場合は再生成する。既存ファイルは絶対に上書きしない。長さは完成したassetの実測秒数を最も近い秒へ丸めて表記する。上限表記は05m00s。丸め方をテストに固定する。ファイル名はファイルから再取得できる管理情報だけで完結する。

録画中は最終保存ディレクトリ内の `.recording-{UUID}.partial.mp4` に書き込む。完成後にwriterの成功、映像・音声トラック、有限な正の尺を検査し、最終名へ同一ボリューム内でrenameする。録画ボタンを止めた時点ではなく、finishとrenameが成功した後にだけ保存完了を表示する。

失敗時は正常な最終名を付けない。再生可能な部分保存ができた場合は、例えば `...-interrupted.mp4` として異常終了だと分かる名前にし、UIでも通知する。読めるか不明なpartialは残し、場所と理由を知らせる。自動削除や「必ず修復できます」との表示はしない。通常のMP4がプロセス強制終了に完全耐性を持つ前提にしない。高度な修復や断片MP4はMVPの必須範囲外。

開始前に保存先の書き込み可否と空き容量を確認する。録画途中の容量不足、権限エラー、外付けボリューム切断も処理する。アプリの出力以外のファイルを削除しない。録画をネットワーク越しに直接保存する運用はMVPの保証対象にしない。

## 9. スレッド・負荷・停止時の事故を防ぐ

- UI更新はMainActor。capture sessionの構築・開始停止は専用直列queue。
- capture callbackでUI操作、ファイル操作、同期wait、大量の画像変換をしない。
- writerへのappend・stop・finishの状態遷移は単一の直列実行境界で管理する。
- sample bufferを別queueへ渡す場合は所有権を保持し、無制限に積み上げない。
- 映像は遅延フレーム破棄を許可し、破棄数を診断情報に残す。音声の欠落を無断で隠さない。
- `isReadyForMoreMediaData` を尊重する。待ちを実装する場合は小さな有界キューを使い、busy loopやcapture callbackのブロックを避ける。持続的なbackpressureは異常停止扱いにする。
- Swift concurrency警告を一括抑制しない。`@unchecked Sendable` が必要なら、対象を最小にしてqueue confinementの根拠を書く。

録画中・保存中だけ通常のアイドルスリープを抑制する。ユーザーが明示的にスリープした場合は割り込みとして扱う。メインウィンドウを閉じる操作やアプリ終了は、録画中なら停止・保存を試みてから処理する。保存待ちが永久に続かないようtimeoutとエラー表示を用意する。システム強制終了・電源断の完全保証はしない。

## 10. 権限と配布形態

このアプリに必要な取得権限はカメラと音声入力。Info.plistには `NSCameraUsageDescription` と `NSMicrophoneUsageDescription` を入れ、権限状態を確認してからcaptureを開始する。[A7] RME入力を録る方式なので、Core Audio Process Tap用のシステム音声取得を要求しない。

必要に応じ、採用する署名・hardened runtime構成に合ったカメラ/音声入力entitlementを設定する。権限拒否時にクラッシュしない。フルディスクアクセス、画面収録、アクセシビリティを回避策として要求しない。`tccutil reset` を全アプリ対象で実行しない。

個人用ローカルアプリ。App Store公開、課金、notarizationは対象外。新規作成ならApp Sandboxなしを標準とし、権限周辺を不必要に複雑化しない。ユーザーが選んだ保存先と設定を正常に復元できることを優先する。

既存のXcodeプロジェクトがあればそれを使う。空の作業ディレクトリなら、**Swift Package + .appを組み立てるスクリプト**を第一選択にし、XcodeGen等の追加インストールを必須にしない。SwiftUI実行ファイルを作るだけで終わらず、Info.plistを含む正規の `.app` bundleを生成する。

固定のbundle identifierと起動パスを使う。ローカルad-hoc署名等、実環境で使える署名方法を選び、再署名後に権限再確認が必要になり得ることを説明する。開発者アカウントや証明書を勝手に前提にしない。自動でHomebrewパッケージを追加しない。

Swiftの言語モードは既存プロジェクト優先。新規は実装環境の安定したモードを明示し、Swift 6 strict concurrency対応そのものを目的化しない。最低OSとSDKの不整合はbuildで解消する。

## 11. サブエージェントを使った進め方

**親エージェントは計画だけで終わらず、統合と動作確認の責任を持つ。利用可能なサブエージェント機能があれば実際に使用する。なければ同じ担当境界で順次実装し、利用していない機能を利用したと報告しない。**

### 11.1 最初に親が行うこと

1. 既存AGENTS.md、ディレクトリ、git status、macOS/SDK/Swift/toolchain、利用可能な並列機能を確認する。既存変更を巻き戻さない。
2. 環境と必要APIを短く検証し、前述の単一capture session方式を基本方針として確定する。
3. ビルド骨格と共有データ型、依存方向、queue所有権を作る。子に異なる設計を独立発明させない。
4. 小さなビルドが通る時点で担当を並列化する。調査だけのエージェントを何体も増やさない。

新規時のディレクトリ案：

```text
Package.swift                         # 親だけが変更
Sources/PracticeRecorderCore/         # 設定値・命名・純粋ロジック
Sources/PracticeRecorderMedia/
  Capture/                            # Agent A
  Recording/                          # Agent B
Sources/PracticeRecorderApp/
  UI/                                 # Agent C
  Settings/                           # Agent C
  RecordingController.swift           # 親
  PracticeRecorderApp.swift            # 親
AppResources/Info.plist                # 親
scripts/build-app.sh                  # 親
scripts/test.sh                       # 親
Tests/                                # 担当別の独立ファイル
README.md                             # 親
TEST_RESULTS.md                       # 親が結果を統合
```

### 11.2 最低限の共有契約

親が、実際のSwift型/メソッドとして次の意味を固定してから子を起動する。

| 契約 | 内容 |
|---|---|
| Instrument | guitar / bass / drums / piano / other のslugと表示名 |
| CaptureSelection | カメラID、音声デバイスID、0始まりL/R、実際の映像設定 |
| RecordingSettings | 保存ルート、画質、audioOffsetMs、上限300秒 |
| RecordingContext | recording ID、不変の設定snapshot、確定した開始日時・PTS |
| CapturePipeline | 設定、開始/停止、プレビュー用session、音声/映像buffer、診断/error |
| MediaWriter | 1テイクの開始・append・finish、実際の尺、結果/error。UIを所有しない |
| RecordingController | 状態の唯一の所有者。開始、手動/自動停止、watchdog、保存確定 |
| FileNaming | 日時と実測尺から保存名を作る純粋処理。上書き防止は保存処理 |

`CMSampleBuffer` の受け渡しqueueと所有権も契約に含める。型名の細部は変更可能だが、子が勝手に共有契約を書き換えない。変更が必要なら親に理由と差分を返し、親が統合する。

### 11.3 並列担当

| 担当 | 実装・テスト対象 | 触らないもの |
|---|---|---|
| Agent A：capture/audio | デバイス列挙、単一capture session、プレビュー接続、ネイティブ音声取得、L/R抽出、メーター、入力断検出。合成多chテスト | UI、writer、ビルド設定、共有型 |
| Agent B：writer/timing | HEVC/AAC MP4 writer、PTS/offset、300秒境界、backpressure、冪等finish。合成bufferと境界テスト | capture設定、UI、プロジェクト構造 |
| Agent C：UI/settings/files | SwiftUI画面、設定永続化、命名・保存補助、Finder操作、UIと命名のテスト。モデルは親契約を使用 | session、writer、共通controller |
| 親：統合 | 状態機械、watchdog、権限、終了処理、app bundle、ビルド、統合試験、README/検証結果 | 他担当への無断の同時上書き |

並列枠が2つならA/Bを子に渡し、親がCも担当する。各子は「変更ファイル、実装要点、実行したテストと結果、未検証事項」を報告する。別worktree方式なら親だけが取り込みを行い、未確認の並列mergeや強制resetをしない。

統合後、空いた子に**レビュー専任**を依頼する。観点は300秒停止の競合、音声ch取り違え、PTS、バッファ寿命、保存失敗、既存RME設定への副作用。レビュー担当は原則ファイルを変更せず、親が指摘を反映する。

## 12. 実装の順序

**段階1：小さく実機経路を確かめる。** カメラのプレビュー、RMEデバイスと実際の音声形式の表示、任意L/Rのメーターまで。最初にこの経路を確認すれば、UI完成後に音声チャンネルが取れない事実が判明する手戻りを避けられる。

**段階2：短いMP4を保存。** 共通PTSで映像＋選択済み音声を5〜10秒録画し、codec、tracks、duration、再生を確認する。5分の自動停止テストとは別の短時間動作確認。

**段階3：完成動作。** 状態機械、watchdog、300秒境界、命名、設定、切断処理、終了処理、実際の.appに統合する。

**段階4：レビューと修正。** 通常経路と異常経路のテストを実行してから完了報告する。実機がない場合も、合成入力によるテスト、ビルド、起動可能なapp bundle作成までは、可能な範囲で完遂する。

## 13. 受入条件とテスト

### 自動テスト

- 命名：各楽器、日付またぎ、月またぎ、秒の丸め、衝突時の非上書き、失敗時に正常名を付けない。
- 音声：例として20chの合成PCMで各chに異なる値を入れ、任意の離れたL/Rだけが出ること。0/1始まり、左右反転、interleaved/non-interleaved、44.1/48kHz、無効indexを検証。実機のチャンネル番号をこのテスト値に固定しない。
- 音声補正：+100msで遅く、−100msで早くなる。開始前/300秒後の処理を検証。
- 状態：開始連打、arming中停止、手動停止とtimeoutの同時発生、保存中再開始、入力断と停止の同時発生。finishとrenameが1回だけ。
- 時間：偽の単調時計で299.9秒→300秒→300.1秒を進める。UI更新停止、壁時計の変更、古いテイクのtimerでも正しく動く。
- 出力境界：合成メディアPTSで300秒を越える音声・映像を渡し、受理範囲と終端を検査する。unit testのため実時間で5分待たない。
- エラー：権限なし、音声バッファなし、無音、カメラなし、選択deviceなし、保存先不可、writer失敗、容量不足、切断。

### macOS上の結合試験

実行できる環境では、合成動画フレーム＋ステレオ音声を実際のwriterに渡してMP4を生成し、AVAssetで映像/音声トラック、HEVC、AAC、尺、開始時刻を確認する。ハードウェアエンコーダーがない環境でこの試験をskipする場合、理由を出力する。ソフトウェアへ黙って切り替えて合格させない。

### ユーザー環境での手動試験

| 試験 | 合格条件 |
|---|---|
| 初回起動 | カメラ・音声入力の許可、保存先とデバイス設定ができる |
| RME設定 | 選んだLoopbackペアのみが録音され、他の入力音が混ざらない |
| Live併用 | Liveの再生・モニターが継続し、サンプルレートや出力設定が変更されない |
| 短い録画 | プレビューを見ながら録画、手動停止、正しい名前のMP4をQuickTimeで再生できる |
| 5分放置 | 05:00で停止・保存し、勝手に次の録画を始めない |
| 画面非アクティブ | Live等を操作中でも、アプリ最小化中でも5分で停止する |
| 音声無音 | 有効な無音PCMを含む録画を正常に保存できる |
| 同期 | 冒頭・末尾のクラップ等でずれを比較。固定補正後の残差と変化量を記録する |
| 連続使用 | 手動で3テイク録画してファイルが3本。履歴DBは生成されない |
| 再起動 | デバイス・L/R・保存先・楽器選択が復元される。録画は自動開始しない |
| 切断 | RME/カメラ切断を通知し、偽の正常保存表示や内蔵マイクへの切替をしない |
| 終了 | 録画中の終了で保存を試み、無期限にハングしない |

同期の初期目標は、固定補正後の知覚できるずれを小さくし、5分でずれが増えないこと。数値を出せる場合は、冒頭と末尾の差の変化を1映像フレーム以内に収めることを目標にする。測定できなければ「未測定」と記載し、合格扱いにしない。

## 14. READMEに入れるRMEセットアップ

RMEの公式マニュアルでは、LoopbackはHardware Outputのサブミックスを対応する録音入力へ戻す機能である。Loopbackを有効にした対応入力では、物理入力の代わりにその出力サブミックスが録音アプリへ送られる。[R1]

次を短く説明する。

1. 既存の楽器入力・モニターを邪魔しない出力/対応入力ペアをユーザーが選ぶ。具体的なペアを「空いている」と断定しない。
2. そのHardware Outputのサブミックスへ、Liveが出しているSoftware Playbackを送る。
3. 録りたいのがLiveの音だけなら、同じ演奏の生入力を重複して混ぜない。
4. その出力のLoopbackをONにし、本アプリで対応する入力L/Rを選ぶ。
5. 本アプリのL/Rメーターとテスト録画で確認する。TotalMixの物理入力メーターだけでLoopbackの収録状態を判断しない。
6. Live側でLoopback入力を同じ出力へ再モニターしない。アプリ自身には音声出力がない。

ADATはサンプルレートにより有効なチャンネルが減る。UCX IIのマニュアルには、高レートでもCore Audioのチャンネルが見えていながら一部が非アクティブになる場合が記載されている。[R2] 列挙されたチャンネル数だけで、信号が有効だと断定しない。

## 15. 完了時の納品・報告

納品するもの：ソース一式、再現可能なbuild/testスクリプト、起動可能な `.app`、README、テスト、TEST_RESULTS.md。環境上.appをビルドできなければ、その事実と不足条件を明示し、ソースと手順を納品する。

READMEには起動方法、必要権限、RME設定、保存規則、5分停止、設定変更、A/V補正の符号、既知の制約を記載する。TEST_RESULTS.mdには、実行したコマンド・環境・結果と、未実行の試験を分ける。

最終報告は以下を簡潔に提示する。

- 実装できた機能と起動する.appの場所。
- 実際に実行したbuild/testコマンドと結果。
- 実機未検証・未測定・残った不具合。
- ユーザーが最初に行うRMEペア選択と短時間録画の手順。

**「理論上動く」「サブエージェントに依頼した」で完了しない。存在しないAPI、未実行の成功ログ、未確認の実機動作を作らない。迷ったら機能を増やさず、録画・停止・安全な保存の正常系を完成させる。**

## 16. 一次資料・参照先

APIの正確なシグネチャ・availabilityは実装環境のSDKを最終確認する。以下は2026-10-29に確認した参照先。本文の具体的なUI、ビットレート、queue構成、テスト条件は本プロジェクトの設計判断であり、メーカーの保証ではない。

```text
[A1] Apple — AVCaptureSession synchronizationClock / masterClock
https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock
https://developer.apple.com/documentation/avfoundation/avcapturesession/masterclock

[A2] Apple — AVCaptureAudioDataOutput.audioSettings
https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput/audiosettings

[A3] Apple — AVAudioConverter.channelMap
https://developer.apple.com/documentation/avfaudio/avaudioconverter/channelmap

[A4] Apple — AVVideoEncoderSpecificationKey
https://developer.apple.com/documentation/avfoundation/avvideoencoderspecificationkey

[A5] Apple — RequireHardwareAcceleratedVideoEncoder
https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder

[A6] Apple — AVAssetWriter session timing
https://developer.apple.com/documentation/avfoundation/avassetwriter/startsession(atsourcetime:)
https://developer.apple.com/documentation/avfoundation/avassetwriter/endsession(atsourcetime:)

[A7] Apple — Requesting Authorization for Media Capture on macOS
https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos

[R1] RME — Fireface UCX II User's Guide, section 27.6, printed p.84
[R2] RME — same guide, section 15.4, printed p.35
https://rme-audio.de/downloads/fface_ucx2_e.pdf
```
