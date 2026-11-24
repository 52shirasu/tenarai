import Foundation
import Core

struct ContextSprintCase: Codable {
    let group: String
    let raw: String
    let left: String
    let right: String
    let expected: String
}

// Synthetic phrases only. Keep each context comparison free of learned test output.
let contextSprintCases: [ContextSprintCase] = [
    .init(group:"同音異義語", raw:"hashi", left:"川にかかる", right:"を渡る", expected:"橋"),
    .init(group:"同音異義語", raw:"hashi", left:"食事に使う", right:"を持つ", expected:"箸"),
    .init(group:"同音異義語", raw:"hashi", left:"机の", right:"に寄せる", expected:"端"),
    .init(group:"同音異義語", raw:"kami", left:"印刷する", right:"を買う", expected:"紙"),
    .init(group:"同音異義語", raw:"kami", left:"美容院で", right:"を切る", expected:"髪"),
    .init(group:"同音異義語", raw:"kami", left:"神社の", right:"に祈る", expected:"神"),
    .init(group:"同音異義語", raw:"ame", left:"空から", right:"が降る", expected:"雨"),
    .init(group:"同音異義語", raw:"ame", left:"甘い", right:"をなめる", expected:"飴"),
    .init(group:"同音異義語", raw:"koushou", left:"価格について", right:"する", expected:"交渉"),
    .init(group:"同音異義語", raw:"koushou", left:"史料を調べて時代を", right:"する", expected:"考証"),
    .init(group:"専門用語", raw:"kikai", left:"工場の", right:"を修理する", expected:"機械"),
    .init(group:"会話", raw:"kikai", left:"また会う", right:"があれば", expected:"機会"),
    .init(group:"専門用語", raw:"shiyou", left:"APIの", right:"を確認する", expected:"仕様"),
    .init(group:"会話", raw:"shiyou", left:"この道具を", right:"する", expected:"使用"),
    .init(group:"専門用語", raw:"kansuu", left:"微分可能な", right:"を定義する", expected:"関数"),
    .init(group:"専門用語", raw:"gyouretu", left:"固有値を求める", right:"の積", expected:"行列"),
    .init(group:"専門用語", raw:"kouzou", left:"データの", right:"を設計する", expected:"構造"),
    .init(group:"専門用語", raw:"henkan", left:"文字コードを", right:"する", expected:"変換"),
    .init(group:"同音異義語", raw:"henkan", left:"借りた資料を", right:"する", expected:"返還"),
    .init(group:"専門用語", raw:"shougai", left:"サーバーの", right:"を調査する", expected:"障害"),
    .init(group:"同音異義語", raw:"shougai", left:"一度きりの", right:"を過ごす", expected:"生涯"),
    .init(group:"会話", raw:"tottokimasuyo", left:"ちゃんと動画も", right:"", expected:"撮っときますよ"),
    .init(group:"会話", raw:"totteokimasuyo", left:"ちゃんと動画も", right:"", expected:"撮っておきますよ"),
    .init(group:"会話", raw:"toru", left:"カメラで写真を", right:"", expected:"撮る"),
    .init(group:"会話", raw:"toru", left:"棚の上の本を", right:"", expected:"取る"),
    .init(group:"会話", raw:"au", left:"友人に", right:"予定です", expected:"会う"),
    .init(group:"会話", raw:"au", left:"サイズが", right:"服", expected:"合う"),
    .init(group:"会話", raw:"naosu", left:"バグを", right:"", expected:"直す"),
    .init(group:"会話", raw:"naosu", left:"風邪を", right:"", expected:"治す"),
    .init(group:"関西弁", raw:"shirankedo", left:"詳しくは", right:"", expected:"知らんけど"),
    .init(group:"関西弁", raw:"nanishitennen", left:"こんな時間に", right:"", expected:"何してんねん"),
    .init(group:"関西弁", raw:"ikahen", left:"今日は", right:"", expected:"行かへん"),
    .init(group:"関西弁", raw:"honmanitasukaruwa", left:"手伝ってくれて", right:"", expected:"ほんまに助かるわ"),
    .init(group:"英数字混在", raw:"sa-ba-", left:"Dockerの", right:"を再起動する", expected:"サーバー"),
    .init(group:"英数字混在", raw:"settei", left:"iPhoneの", right:"を変更する", expected:"設定"),
    .init(group:"英数字混在", raw:"1230", left:"集合時刻は", right:"です", expected:"12:30"),
    .init(group:"長文", raw:"kyouhatenkigayoinodesanponiikimasu", left:"予定が空いたので", right:"", expected:"今日は天気が良いので散歩に行きます"),
    .init(group:"長文", raw:"konokinounoseinouwokakuninsimasu", left:"次のテストでは", right:"", expected:"この機能の性能を確認します"),
    .init(group:"会話", raw:"ohayougozaimasu", left:"みなさん", right:"", expected:"おはようございます"),
    .init(group:"専門用語", raw:"kakuritu", left:"事象が起こる", right:"を求める", expected:"確率")
,
    // Added before the September 27 changes; keep separate from the original 40.
    .init(group:"追加同音語", raw:"haisuikou", left:"台所の", right:"が詰まった", expected:"排水口"),
    .init(group:"追加同音語", raw:"haisuikou", left:"道路沿いの", right:"を掃除する", expected:"排水溝"),
    .init(group:"追加同音語", raw:"kaitou", left:"冷凍した肉を", right:"する", expected:"解凍"),
    .init(group:"追加同音語", raw:"kaitou", left:"質問への", right:"をお願いします", expected:"回答"),
    .init(group:"追加同音語", raw:"hoshou", left:"製品の品質を", right:"する", expected:"保証"),
    .init(group:"追加同音語", raw:"hoshou", left:"事故の損害を", right:"する", expected:"補償"),
    .init(group:"追加同音語", raw:"taishou", left:"二つの図形は左右", right:"です", expected:"対称"),
    .init(group:"追加同音語", raw:"taishou", left:"調査の", right:"を選ぶ", expected:"対象"),
    .init(group:"追加会話", raw:"konnichiwa", left:"みなさん", right:"", expected:"こんにちは"),
    .init(group:"追加会話", raw:"konnanikanntan", left:"設定が", right:"だとは思わなかった", expected:"こんなに簡単"),
    .init(group:"追加関西弁", raw:"nanishitennnen", left:"こんな時間に", right:"", expected:"何してんねん"),
    .init(group:"追加関西弁", raw:"soremettyaomoroiyan", left:"", right:"", expected:"それめっちゃおもろいやん"),
    .init(group:"追加関西弁", raw:"kyouhaikahen", left:"雨やし", right:"", expected:"今日は行かへん"),
    .init(group:"追加関西弁", raw:"koremitoitena", left:"あとで", right:"", expected:"これ見といてな"),
    .init(group:"追加誤入力", raw:"ohayougzaimasu", left:"みなさん", right:"", expected:"おはようございます"),
    .init(group:"追加誤入力", raw:"arigatougoziamasu", left:"いつも", right:"", expected:"ありがとうございます"),
    .init(group:"追加専門", raw:"hairetu", left:"プログラムの", right:"の要素を追加する", expected:"配列"),
    .init(group:"追加専門", raw:"kousei", left:"サーバーの", right:"を変更する", expected:"構成"),
    .init(group:"追加長文", raw:"ashitanoyoteiwokakuninsimasu", left:"会議の前に", right:"", expected:"明日の予定を確認します"),
    .init(group:"追加長文", raw:"syashinwototteokimasu", left:"記録のため", right:"", expected:"写真を撮っておきます")
]
