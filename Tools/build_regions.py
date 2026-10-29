#!/usr/bin/env python3
"""把行政区边界 GeoJSON 预处理成 app 内置的 Regions.bin（格式见 docs/regions-design.md）。纯标准库。

用法：
  build_regions.py --countries ne_10m_admin_0_countries.geojson --admin1 ne_10m_admin_1_states_provinces.geojson \
                   [--china-dir datav_bounds/] --out GPXPointViewer/Regions.bin [--tolerance-m 150] [--tolerance-m-l2 50]
                   [--datav-datum gcj02|wgs84]
  build_regions.py --synthetic out.bin         # 两个假国家（基础单元测试）
  build_regions.py --synthetic2 out.bin        # 刁钻几何：凸出、飞地、窄条、小岛、跨日界线、梵蒂冈式微型国、跨国格

层级：0 国家（NE admin0）、1 省/州（NE admin1，按 adm0_a3 / iso 挂到国家）、2 中国地级（DataV <省 adcode>_full.json，
按文件名 / parent.adcode 的 adcode 挂到 NE 的中国省份）。名称四语：zh-Hans / en / de / zh-Hant（缺的 app 端按链回退）。
"""
import sys, json, math, struct, argparse, os, re, glob

R = 6371008.8
def dp_simplify(pts, tol_deg):
    """Douglas-Peucker（经纬度平面近似），保首尾"""
    if len(pts) <= 3 or tol_deg <= 0: return pts
    def perp(p, a, b):
        ax, ay = a; bx, by = b; px, py = p
        dx, dy = bx - ax, by - ay
        if dx == 0 and dy == 0: return math.hypot(px - ax, py - ay)
        t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy); t = max(0.0, min(1.0, t))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))
    keep = [False] * len(pts); keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1: continue
        dmax, k = 0.0, -1
        a, b = pts[i], pts[j]
        for m in range(i + 1, j):
            d = perp(pts[m], a, b)
            if d > dmax: dmax, k = d, m
        if dmax > tol_deg: keep[k] = True; stack.append((i, k)); stack.append((k, j))
    return [p for p, kf in zip(pts, keep) if kf]

def ring_area_km2(ring):
    """球面多边形面积（经纬度，等面积近似：按纬度 cos 校正的鞋带公式分段）"""
    if len(ring) < 3: return 0.0
    area = 0.0
    for i in range(len(ring)):
        lon1, lat1 = ring[i]; lon2, lat2 = ring[(i + 1) % len(ring)]
        area += math.radians(lon2 - lon1) * (2 + math.sin(math.radians(lat1)) + math.sin(math.radians(lat2)))
    return abs(area * R * R / 2) / 1e6

def iter_polys(geom):
    """→ [ [outer, hole, hole...], ... ] 每个 ring 是 [(lon,lat)]"""
    t = geom.get("type")
    if t == "Polygon": return [[[tuple(c[:2]) for c in r] for r in geom["coordinates"]]]
    if t == "MultiPolygon": return [[[tuple(c[:2]) for c in r] for r in poly] for poly in geom["coordinates"]]
    return []

# ---- GCJ-02（高德/DataV）→ WGS-84：标准变换的迭代反解，误差 < 0.1 m；只在中国境内（变换本身在境外是恒等）----
def _gcj_delta(lon, lat):
    a, ee = 6378245.0, 0.00669342162296594323
    x, y = lon - 105.0, lat - 35.0
    def tf(x, y, base):
        r = base + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
        r += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
        return r
    dlat = tf(x, y, -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x)) - 0.1 * x * y - 0.2 * math.sqrt(abs(x)))
    dlat += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0
    dlat += (160.0 * math.sin(y / 12.0 * math.pi) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    dlon = tf(x, y, 300.0 + x + 2.0 * y + 0.1 * x * x)
    dlon += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0
    dlon += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0
    radlat = lat / 180.0 * math.pi
    magic = 1 - ee * math.sin(radlat) ** 2
    sqrtmagic = math.sqrt(magic)
    dlat = (dlat * 180.0) / ((a * (1 - ee)) / (magic * sqrtmagic) * math.pi)
    dlon = (dlon * 180.0) / (a / sqrtmagic * math.cos(radlat) * math.pi)
    return dlon, dlat
def wgs_to_gcj(lon, lat):
    if lon < 72.004 or lon > 137.8347 or lat < 0.8293 or lat > 55.8271: return lon, lat
    dlon, dlat = _gcj_delta(lon, lat); return lon + dlon, lat + dlat
def gcj_to_wgs(lon, lat):
    wlon, wlat = lon, lat
    for _ in range(4):
        glon, glat = wgs_to_gcj(wlon, wlat)
        wlon -= glon - lon; wlat -= glat - lat
    return wlon, wlat

# ---- 中国省级 adcode ↔ NE 省（ISO 3166-2 两种写法 + 中文简称）----
CN_PROVINCES = {
    110000: ("北京", "BJ", "11"), 120000: ("天津", "TJ", "12"), 130000: ("河北", "HE", "13"), 140000: ("山西", "SX", "14"),
    150000: ("内蒙古", "NM", "15"), 210000: ("辽宁", "LN", "21"), 220000: ("吉林", "JL", "22"), 230000: ("黑龙江", "HL", "23"),
    310000: ("上海", "SH", "31"), 320000: ("江苏", "JS", "32"), 330000: ("浙江", "ZJ", "33"), 340000: ("安徽", "AH", "34"),
    350000: ("福建", "FJ", "35"), 360000: ("江西", "JX", "36"), 370000: ("山东", "SD", "37"), 410000: ("河南", "HA", "41"),
    420000: ("湖北", "HB", "42"), 430000: ("湖南", "HN", "43"), 440000: ("广东", "GD", "44"), 450000: ("广西", "GX", "45"),
    460000: ("海南", "HI", "46"), 500000: ("重庆", "CQ", "50"), 510000: ("四川", "SC", "51"), 520000: ("贵州", "GZ", "52"),
    530000: ("云南", "YN", "53"), 540000: ("西藏", "XZ", "54"), 610000: ("陕西", "SN", "61"), 620000: ("甘肃", "GS", "62"),
    630000: ("青海", "QH", "63"), 640000: ("宁夏", "NX", "64"), 650000: ("新疆", "XJ", "65"),
}
def norm_cn(s):
    """中文行政区名的匹配键：反复去掉 省/市/自治区/特别行政区 与民族成分后缀"""
    s = (s or "").strip()
    while True:
        s2 = re.sub(r"(省|市|自治区|特别行政区|维吾尔|壮族|回族|地区)$", "", s)
        if s2 == s: break
        s = s2
    return s
def short_cn(name, level):
    """显示用简称（世界迷雾式）：省级去 省/市/自治区/特别行政区 与民族成分；地级去尾字 市 / 区（海淀区→海淀）；自治州/地区/盟原样"""
    n = (name or "").strip()
    if level == 1: return norm_cn(n) or n
    if level == 2 and len(n) > 2 and (n.endswith("市") or (n.endswith("区") and not n.endswith(("地区", "特区", "新区", "林区")))): return n[:-1]
    return n
HKMO = {810000: "HK", 820000: "MO"}     # DataV 港澳分区文件 → NE 里的独立国家；分区挂为它们的一级行政区

# ---- 简体名清洗：NE 的 name_zh 来自 Wikidata，夹着繁体字、台湾译名、全角连字符 ----
_T2S = ("萊莱內内齊齐亞亚蘭兰爾尔島岛區区縣县國国東东門门馬马鎮镇濱滨灣湾聖圣聯联魯鲁達达羅罗倫伦維维奧奥薩萨蘇苏諾诺鳥鸟龍龙鳳凤圖图漢汉華华莊庄嶼屿嶺岭陽阳陰阴關关開开長长廣广慶庆寧宁"
        "貢贡貝贝賓宾賀贺歐欧烏乌錫锡鐵铁銀银錦锦鋼钢緬缅絲丝經经綠绿紅红紐纽約约點点蓋盖濟济澤泽滿满湯汤溫温遜逊遠远運运連连邊边進进選选遷迁鄉乡鄭郑醫医陸陆際际雙双離离電电雲云頓顿頭头顯显風风飛飞體体鮮鲜鹽盐麥麦黃黄為为無无與与業业樂乐樹树橋桥權权歷历歸归氣气獨独現现環环產产"
        "當当發发盤盘眾众確确禮礼種种築筑簡简紀纪納纳級级組组細细終终結结絕绝統统總总織织繼继續续聽听職职臺台興兴舊旧藝艺藥药處处號号衛卫製制見见規规視视覺觉觀观計计認认設设許许話话語语說说調调談谈請请論论謝谢證证識识議议護护讀读變变豐丰貿贸資资賽赛質质賴赖購购贊赞車车軍军載载輕轻輪轮轉转農农適适遺遗還还釋释錢钱錄录鍵键鎖锁間间階阶雜杂靈灵靜静頁页預预領领顏颜願愿類类顧顾飯饭養养餘余館馆駐驻驗验驚惊魚鱼鴨鸭鷹鹰麗丽黨党齒齿寫写專专將将導导層层帶带幫帮幾几廠厂彎弯從从復复懷怀戰战擔担據据擊击擴扩數数斷断時时書书會会條条極极構构標标樣样機机檔档歡欢歲岁殘残滅灭燈灯營营牆墙獎奖獻献瑪玛盧卢礦矿碩硕磚砖禪禅稅税穩稳競竞筆笔節节範范絡络綱纲線线緊紧緯纬縮缩繪绘習习聲声聰聪脫脱臨临蔣蒋蘆芦虛虚衝冲補补裝装覽览詞词誠诚誤误課课諸诸講讲譯译貨货貴贵買买費费賢贤賣卖趙赵跡迹軟软輸输轄辖辭辞遞递鄧邓閉闭閱阅隊队陳陈陣阵險险雖虽頂顶項项順顺題题額额飄飘馮冯驅驱鳴鸣麼么齡龄")
_T2S_EXTRA = ("別别庫库茲兹賈贾傑杰熱热凱凯韋韦憲宪誕诞霧雾揚扬葉叶實实屬属欽钦勞劳訥讷窩窝藍蓝"
              "們们來来個个這这們们對对時时會会過过說说發发經经動动們们還还國国學学實实產产義义現现種种開开關关樣样間间問问電电"
              "們们頭头見见幾几業业員员經经較较處处點点給给數数讓让樂乐轉转語语體体術术門门親亲錯错該该長长進进強强結结務务報报難难"
              "輕轻稱称幹干專专誰谁識识靈灵養养質质導导類类顧顾準准顯显訂订雜杂舊旧請请聲声約约論论隊队辦办達达續续黨党確确際际議议"
              "歡欢壓压備备戰战響响遠远團团織织劃划細细總总環环滿满龍龙屆届兒儿擊击藥药納纳爭争礦矿鐵铁銀银銅铜鋁铝鋼钢錫锡鉛铅鋅锌"
              "塢坞壩坝灘滩澗涧溝沟灣湾淺浅濤涛瀾澜潛潜瀋沈潯浔漁渔濾滤灑洒澆浇濁浊潤润澀涩濕湿灤滦灕漓灝灏瀘泸灄滠潁颍渦涡滸浒"
              "嶽岳崗岗嶺岭嶼屿巒峦崙仑嶸嵘峴岘崬岽嶗崂嶧峄嶴岙"
              "臺台颱台檯台鬱郁慾欲衹只準准劃划"
              "鎮镇鄉乡縣县區区鄰邻郵邮鄒邹鄭郑鄖郧鄲郸鄴邺鄔邬鄆郓鄶郐"
              "寧宁廣广慶庆廈厦廟庙廬庐廳厅龐庞廢废廚厨"
              "張张彎弯強强彈弹彙汇後后復复徑径從从禦御"
              "陝陕陳陈陸陆際际陽阳隴陇隆隆隊队階阶際际險险隨随隱隐陰阴"
              "齊齐齋斋齒齿齡龄龔龚龕龛"
              "魯鲁魚鱼鮮鲜鯉鲤鯨鲸鱗鳞鳥鸟鳳凤鴻鸿鵬鹏鶴鹤鷹鹰鷺鹭鴨鸭鷄鸡鸚鹦鵡鹉"
              "馬马駐驻騎骑騰腾驛驿驪骊駿骏驤骧駝驼"
              "飛飞風风颳刮飄飘飯饭飾饰餘余館馆饒饶饑饥"
              "頁页頂顶頃顷項项順顺須须頑顽頓顿頗颇領领頸颈頭头頻频顆颗題题額额顏颜願愿類类顧顾顫颤"
              "雲云電电霧雾靂雳靜静靈灵靄霭霽霁"
              "門门閃闪閉闭問问閏闰閑闲間间閘闸閣阁閥阀閩闽閱阅闊阔闋阕闌阑闔阖關关"
              "長长鎖锁鍾钟鐘钟鍵键錄录錢钱錦锦鍋锅鏡镜鏈链鑼锣鑽钻鑫鑫銘铭鉤钩鈴铃鈞钧鈺钰"
              "書书畫画晝昼劃划盡尽盤盘監监鹽盐"
              "樹树橋桥機机權权楊杨樓楼標标榮荣榮荣檢检樣样極极構构槍枪櫃柜櫻樱欄栏櫸榉楓枫檔档"
              "華华萬万蘭兰蘇苏薩萨蘆芦藝艺蘿萝薊蓟蔭荫蔣蒋蕭萧藍蓝葉叶莊庄菸烟蓋盖薌芗"
              "島岛嶼屿"
              "灣湾澳澳濱滨"
              "聖圣聯联聽听聲声職职"
              "東东車车軍军軒轩轉转輪轮較较輝辉輯辑輿舆轟轰載载"
              "貝贝財财貢贡貴贵買买賣卖賓宾賀贺資资賽赛質质購购貿贸費费貨货賴赖贊赞贏赢"
              "紅红紀纪約约級级紐纽納纳純纯紹绍終终組组結结絕绝給给統统絲丝經经綠绿維维綜综綱纲網网緬缅線线緯纬編编練练縣县縮缩總总織织繡绣繼继續续纏缠"
              "達达過过運运還还進进遠远選选遷迁遼辽遺遗邊边邏逻適适遲迟連连遞递邁迈逕迳")
_T2S_MAP = {_T2S[i]: _T2S[i + 1] for i in range(0, len(_T2S) - 1, 2)}
for i in range(0, len(_T2S_EXTRA) - 1, 2): _T2S_MAP.setdefault(_T2S_EXTRA[i], _T2S_EXTRA[i + 1])
for k in list(_T2S_MAP):                      # 歧义/保留字不转（干/后/只/台 以外的正常字当键时才生效）
    if k == _T2S_MAP[k]: del _T2S_MAP[k]
_TW_FIX = [("佛罗伦斯", "佛罗伦萨"), ("伯恩州", "伯尔尼州"), ("雪梨", "悉尼"), ("坎培拉", "堪培拉"), ("纽西兰", "新西兰"), ("义大利", "意大利"), ("沙乌地", "沙特"), ("卡达", "卡塔尔"), ("寮国", "老挝"), ("汶莱", "文莱"),
           ("北韩", "朝鲜"), ("南韩", "韩国"), ("衣索比亚", "埃塞俄比亚"), ("肯亚", "肯尼亚"), ("奈及利亚", "尼日利亚"), ("模里西斯", "毛里求斯"), ("塞席尔", "塞舌尔"), ("瓜地马拉", "危地马拉"), ("宏都拉斯", "洪都拉斯"), ("哥斯大黎加", "哥斯达黎加"),
           ("波札那", "博茨瓦纳"), ("辛巴威", "津巴布韦"), ("尚比亚", "赞比亚"), ("莫三比克", "莫桑比克"), ("马拉威", "马拉维"), ("坦尚尼亚", "坦桑尼亚"), ("卢安达", "卢旺达"), ("蒲隆地", "布隆迪"), ("索马利亚", "索马里"), ("吉布地", "吉布提"),
           ("厄利垂亚", "厄立特里亚"), ("突尼西亚", "突尼斯"), ("茅利塔尼亚", "毛里塔尼亚"), ("象牙海岸", "科特迪瓦"), ("迦纳", "加纳"), ("贝南", "贝宁"), ("加彭", "加蓬"), ("史瓦帝尼", "斯威士兰"), ("赖索托", "莱索托"), ("叶门", "也门"),
           ("乔治亚", "格鲁吉亚"), ("亚塞拜然", "阿塞拜疆"), ("蒙特内哥罗", "黑山"), ("波士尼亚", "波斯尼亚"), ("克罗埃西亚", "克罗地亚"), ("斯洛维尼亚", "斯洛文尼亚"), ("列支敦斯登", "列支敦士登"), ("赛普勒斯", "塞浦路斯"), ("马尔他", "马耳他"),
           ("马尔地夫", "马尔代夫"), ("巴布亚纽几内亚", "巴布亚新几内亚"), ("索罗门", "所罗门"), ("万那杜", "瓦努阿图"), ("诺鲁", "瑙鲁"), ("吐瓦鲁", "图瓦卢"), ("吉里巴斯", "基里巴斯"), ("东加", "汤加"), ("帛琉", "帕劳"),
           ("格瑞那达", "格林纳达"), ("圣露西亚", "圣卢西亚"), ("巴贝多", "巴巴多斯"), ("安地卡", "安提瓜"), ("贝里斯", "伯利兹"), ("盖亚那", "圭亚那"), ("苏利南", "苏里南"), ("祕鲁", "秘鲁"),
           ("加地夫", "加的夫"), ("伊斯坦堡", "伊斯坦布尔"), ("西维吉尼亚", "西弗吉尼亚"), ("维吉尼亚", "弗吉尼亚"), ("博尔戈·马吉欧雷", "博尔戈马焦雷"), ("基埃萨努欧瓦", "基耶萨诺瓦"), ("大葛摩", "大科摩罗"), ("欧姆古温", "乌姆盖万"),
           ("图阿莫图·甘比亚", "土阿莫土群岛"), ("伊兹密尔次分区", "伊兹密尔省"), ("里兹市", "利兹市"), ("威克菲尔德", "韦克菲尔德"), ("宿雾", "宿务"), ("蓝毗尼", "蓝毗尼"), ("杰维斯湾", "杰维斯湾")]
def clean_zh(s):
    if not s: return s
    s = "".join(_T2S_MAP.get(c, c) for c in s).replace("－", "-").replace("—", "-").replace("–", "-")
    for a, b in _TW_FIX:
        if a != b and a in s: s = s.replace(a, b)
    return s

# ---- 法/意/西/英：NE 一级给的是省/县，按 region / geonunit 聚成大区（大区作一级，省作二级）----
GROUP_FIELD = {"ITA": "region", "FRA": "region", "ESP": "region", "GBR": "geonunit"}
GROUP_NAMES = {
 "abruzzo": ("阿布鲁佐", "Abruzzo", "Abruzzen"), "basilicata": ("巴西利卡塔", "Basilicata", "Basilikata"), "calabria": ("卡拉布里亚", "Calabria", "Kalabrien"), "campania": ("坎帕尼亚", "Campania", "Kampanien"),
 "emilia-romagna": ("艾米利亚-罗马涅", "Emilia-Romagna", "Emilia-Romagna"), "friuli-venezia giulia": ("弗留利-威尼斯朱利亚", "Friuli-Venezia Giulia", "Friaul-Julisch Venetien"), "lazio": ("拉齐奥", "Lazio", "Latium"),
 "liguria": ("利古里亚", "Liguria", "Ligurien"), "lombardia": ("伦巴第", "Lombardy", "Lombardei"), "lombardy": ("伦巴第", "Lombardy", "Lombardei"), "marche": ("马尔凯", "Marche", "Marken"), "molise": ("莫利塞", "Molise", "Molise"),
 "piemonte": ("皮埃蒙特", "Piedmont", "Piemont"), "piedmont": ("皮埃蒙特", "Piedmont", "Piemont"), "puglia": ("普利亚", "Apulia", "Apulien"), "apulia": ("普利亚", "Apulia", "Apulien"), "sardegna": ("撒丁", "Sardinia", "Sardinien"), "sardinia": ("撒丁", "Sardinia", "Sardinien"),
 "sicilia": ("西西里", "Sicily", "Sizilien"), "sicily": ("西西里", "Sicily", "Sizilien"), "toscana": ("托斯卡纳", "Tuscany", "Toskana"), "tuscany": ("托斯卡纳", "Tuscany", "Toskana"), "trentino-alto adige": ("特伦蒂诺-上阿迪杰", "Trentino-South Tyrol", "Trentino-Südtirol"),
 "umbria": ("翁布里亚", "Umbria", "Umbrien"), "valle d'aosta": ("瓦莱达奥斯塔", "Aosta Valley", "Aostatal"), "veneto": ("威尼托", "Veneto", "Venetien"),
 "auvergne-rhone-alpes": ("奥弗涅-罗讷-阿尔卑斯", "Auvergne-Rhône-Alpes", "Auvergne-Rhône-Alpes"), "bourgogne-franche-comte": ("勃艮第-弗朗什-孔泰", "Bourgogne-Franche-Comté", "Bourgogne-Franche-Comté"),
 "bretagne": ("布列塔尼", "Brittany", "Bretagne"), "centre-val de loire": ("中央-卢瓦尔河谷", "Centre-Val de Loire", "Centre-Val de Loire"), "corse": ("科西嘉", "Corsica", "Korsika"), "grand est": ("大东部", "Grand Est", "Grand Est"),
 "hauts-de-france": ("上法兰西", "Hauts-de-France", "Hauts-de-France"), "ile-de-france": ("法兰西岛", "Île-de-France", "Île-de-France"), "normandie": ("诺曼底", "Normandy", "Normandie"), "nouvelle-aquitaine": ("新阿基坦", "Nouvelle-Aquitaine", "Nouvelle-Aquitaine"),
 "occitanie": ("奥克西塔尼", "Occitanie", "Okzitanien"), "pays de la loire": ("卢瓦尔河地区", "Pays de la Loire", "Pays de la Loire"), "provence-alpes-cote d'azur": ("普罗旺斯-阿尔卑斯-蓝色海岸", "Provence-Alpes-Côte d'Azur", "Provence-Alpes-Côte d'Azur"),
 "guadeloupe": ("瓜德罗普", "Guadeloupe", "Guadeloupe"), "martinique": ("马提尼克", "Martinique", "Martinique"), "guyane": ("法属圭亚那", "French Guiana", "Französisch-Guayana"), "guyane francaise": ("法属圭亚那", "French Guiana", "Französisch-Guayana"), "la reunion": ("留尼汪", "Réunion", "Réunion"), "reunion": ("留尼汪", "Réunion", "Réunion"), "mayotte": ("马约特", "Mayotte", "Mayotte"),
 "alsace": ("阿尔萨斯", "Alsace", "Elsass"), "lorraine": ("洛林", "Lorraine", "Lothringen"), "champagne-ardenne": ("香槟-阿登", "Champagne-Ardenne", "Champagne-Ardenne"), "aquitaine": ("阿基坦", "Aquitaine", "Aquitanien"), "limousin": ("利穆赞", "Limousin", "Limousin"),
 "poitou-charentes": ("普瓦图-夏朗德", "Poitou-Charentes", "Poitou-Charentes"), "midi-pyrenees": ("南部-比利牛斯", "Midi-Pyrénées", "Midi-Pyrénées"), "languedoc-roussillon": ("朗格多克-鲁西永", "Languedoc-Roussillon", "Languedoc-Roussillon"), "auvergne": ("奥弗涅", "Auvergne", "Auvergne"),
 "rhone-alpes": ("罗讷-阿尔卑斯", "Rhône-Alpes", "Rhône-Alpes"), "bourgogne": ("勃艮第", "Burgundy", "Burgund"), "franche-comte": ("弗朗什-孔泰", "Franche-Comté", "Franche-Comté"), "nord-pas-de-calais": ("北部-加来海峡", "Nord-Pas-de-Calais", "Nord-Pas-de-Calais"), "picardie": ("皮卡第", "Picardy", "Picardie"),
 "haute-normandie": ("上诺曼底", "Upper Normandy", "Haute-Normandie"), "basse-normandie": ("下诺曼底", "Lower Normandy", "Basse-Normandie"), "centre": ("中央", "Centre", "Centre"),
 "andalucia": ("安达卢西亚", "Andalusia", "Andalusien"), "aragon": ("阿拉贡", "Aragon", "Aragonien"), "asturias": ("阿斯图里亚斯", "Asturias", "Asturien"), "principado de asturias": ("阿斯图里亚斯", "Asturias", "Asturien"), "islas baleares": ("巴利阿里群岛", "Balearic Islands", "Balearen"), "baleares": ("巴利阿里群岛", "Balearic Islands", "Balearen"), "illes balears": ("巴利阿里群岛", "Balearic Islands", "Balearen"),
 "canarias": ("加那利群岛", "Canary Islands", "Kanarische Inseln"), "cantabria": ("坎塔布里亚", "Cantabria", "Kantabrien"), "castilla y leon": ("卡斯蒂利亚-莱昂", "Castile and León", "Kastilien und León"), "castilla-la mancha": ("卡斯蒂利亚-拉曼恰", "Castile-La Mancha", "Kastilien-La Mancha"),
 "cataluna": ("加泰罗尼亚", "Catalonia", "Katalonien"), "catalunya": ("加泰罗尼亚", "Catalonia", "Katalonien"), "comunidad valenciana": ("巴伦西亚", "Valencian Community", "Valencia"), "valenciana": ("巴伦西亚", "Valencian Community", "Valencia"), "extremadura": ("埃斯特雷马杜拉", "Extremadura", "Extremadura"),
 "galicia": ("加利西亚", "Galicia", "Galicien"), "comunidad de madrid": ("马德里", "Community of Madrid", "Autonome Gemeinschaft Madrid"), "madrid": ("马德里", "Community of Madrid", "Autonome Gemeinschaft Madrid"), "region de murcia": ("穆尔西亚", "Region of Murcia", "Region Murcia"), "murcia": ("穆尔西亚", "Region of Murcia", "Region Murcia"),
 "comunidad foral de navarra": ("纳瓦拉", "Navarre", "Navarra"), "navarra": ("纳瓦拉", "Navarre", "Navarra"), "pais vasco": ("巴斯克", "Basque Country", "Baskenland"), "la rioja": ("拉里奥哈", "La Rioja", "La Rioja"), "ceuta": ("休达", "Ceuta", "Ceuta"), "melilla": ("梅利利亚", "Melilla", "Melilla"),
 "canary is.": ("加那利群岛", "Canary Islands", "Kanarische Inseln"), "foral de navarra": ("纳瓦拉", "Navarre", "Navarra"), "provence-alpes-cote-d'azur": ("普罗旺斯-阿尔卑斯-蓝色海岸", "Provence-Alpes-Côte d'Azur", "Provence-Alpes-Côte d'Azur"),
 "england": ("英格兰", "England", "England"), "scotland": ("苏格兰", "Scotland", "Schottland"), "wales": ("威尔士", "Wales", "Wales"), "northern ireland": ("北爱尔兰", "Northern Ireland", "Nordirland"),
}
_S2T_MAP = {v: k for k, v in _T2S_MAP.items()}        # 大区名的繁体：按字表反推（这些名字里没有一简对多繁的歧义字）
def to_hant(s): return "".join(_S2T_MAP.get(c, c) for c in (s or ""))
def norm_key(s):
    import unicodedata
    s = unicodedata.normalize("NFKD", s or ""); s = "".join(c for c in s if not unicodedata.combining(c))
    return s.lower().strip().replace("’", "'")
COUNTRY_NAME_OVERRIDE = {"CN": {"zh-Hans": "中国", "zh-Hant": "中國"}, "TW": {"zh-Hans": "台湾", "zh-Hant": "台灣", "en": "Taiwan", "de": "Taiwan"}}

class Builder:
    def __init__(self, tol_m):
        self.tol_m = tol_m
        self.regions = []       # dict(level,parent,iso2,area,names,polys=[[ring,...]])
        self.names = bytearray(); self.name_off = {}
    def name(self, s):
        s = s or ""
        if s in self.name_off: return self.name_off[s]
        off = len(self.names); self.names += s.encode("utf-8") + b"\0"; self.name_off[s] = off; return off
    def add(self, level, parent, iso2, names, geom, area=None, min_ring_km2=0.5, tol_m=None, transform=None):
        """一块地区。最大的那个多边形永远保留（微型国家/小岛不消失），min_ring_km2 只筛其余的小岛；洞一律保留（洞是别人的飞地）。
        简化容差对小地区自适应：tol = min(tol_m, 5% × √面积)，1 km² 的地方只容 50 m。"""
        tol_m = self.tol_m if tol_m is None else tol_m
        raw = iter_polys(geom)
        if transform:
            raw = [[[transform(lon, lat) for lon, lat in ring] for ring in poly] for poly in raw]
        cands = []
        for poly in raw:
            if len(poly[0]) < 4: continue
            a0 = ring_area_km2(poly[0])
            # < 5 km² 的环（微型国家、飞地及其在邻区里的洞）原样保留：洞和飞地外环各自简化会在边上留缝
            t = 0.0 if a0 < 5 else min(tol_m, 0.05 * math.sqrt(a0) * 1000) / 111_000.0
            outer = dp_simplify(poly[0], t)
            if len(outer) < 4: outer = poly[0]
            holes = []
            for h in poly[1:]:
                if len(h) < 4: continue
                ah = ring_area_km2(h)
                hs = dp_simplify(h, 0.0 if ah < 5 else min(t, 0.05 * math.sqrt(ah) * 1000 / 111_000.0))
                holes.append(hs if len(hs) >= 4 else h)
            cands.append((a0, [outer] + holes))
        if not cands: return None
        cands.sort(key=lambda c: -c[0])
        polys = [cands[0][1]] + [p for a0, p in cands[1:] if a0 >= min_ring_km2]
        if area is None:
            area = sum(ring_area_km2(p[0]) - sum(ring_area_km2(h) for h in p[1:]) for p in polys)
        iso2 = (iso2 or "").strip().upper()
        if not re.fullmatch(r"[A-Z]{2}", iso2): iso2 = ""
        self.regions.append(dict(level=level, parent=parent, iso2=iso2, area=area, names=names, polys=polys))
        return len(self.regions) - 1
    def write(self, out):
        assert len(self.regions) < 0xFFFE, "too many regions for u16 ids"
        rings = []; verts = []; region_recs = []
        grid = [[] for _ in range(360 * 180)]
        for rid, r in enumerate(self.regions):
            ring_start = len(rings); bb = [90.0, 180.0, -90.0, -180.0]
            assert r["polys"] and r["polys"][0], f"region {rid} has no outer ring"
            for poly in r["polys"]:
                assert len(poly[0]) >= 4, f"region {rid}: first ring of a polygon must be an outer ring"
                for hi, ring in enumerate(poly):          # 顺序约定：外环后面紧跟它自己的洞（app 端据此分组）
                    vs = len(verts)
                    rb = [90.0, 180.0, -90.0, -180.0]
                    for lon, lat in ring:
                        verts.append((int(round(lat * 1e6)), int(round(lon * 1e6))))
                        rb = [min(rb[0], lat), min(rb[1], lon), max(rb[2], lat), max(rb[3], lon)]
                    rings.append((vs, len(ring), 1 if hi > 0 else 0, rb))
                    bb = [min(bb[0], rb[0]), min(bb[1], rb[1]), max(bb[2], rb[2]), max(bb[3], rb[3])]
                    if hi == 0:
                        for la in range(int(math.floor(rb[0] + 90)), int(math.floor(rb[2] + 90)) + 1):
                            for lo in range(int(math.floor(rb[1] + 180)), int(math.floor(rb[3] + 180)) + 1):
                                la2, lo2 = max(0, min(179, la)), max(0, min(359, lo))
                                cell = grid[la2 * 360 + lo2]
                                if rid not in cell: cell.append(rid)
            n = r["names"]
            region_recs.append((rid, r["level"], r["parent"] if r["parent"] is not None else 0xFFFF, r["iso2"], r["area"], bb,
                                ring_start, len(rings) - ring_start,
                                self.name(n.get("zh-Hans")), self.name(n.get("en")), self.name(n.get("de")), self.name(n.get("zh-Hant"))))
        # 格索引：按 level 降序（细的在前：查询先试市再省再国），同级按 id 升序
        lvl = {rid: r["level"] for rid, r in enumerate(self.regions)}
        area = {rid: r["area"] for rid, r in enumerate(self.regions)}
        cell_lists = []; cell_offsets = []
        for cell in grid:
            cell.sort(key=lambda rid: (-lvl[rid], area[rid] if lvl[rid] > 0 else 0, rid))   # 细的在前；省/市同级小的在前；国家层 app 端按最小外环裁决
            cell_offsets.append((len(cell_lists), len(cell))); cell_lists.extend(cell)
        with open(out, "wb") as f:
            f.write(b"RGN1"); f.write(struct.pack("<I", 1))
            f.write(struct.pack("<IIII", len(region_recs), len(rings), len(verts), 360 * 180))
            for rec in region_recs:
                rid, level, parent, iso2, area, bb, rs, rc, n0, n1, n2, n3 = rec
                f.write(struct.pack("<HBH2sfffffIHIIII", rid, level, parent, iso2.encode("ascii", "replace").ljust(2, b" ")[:2], area,
                                    bb[0], bb[1], bb[2], bb[3], rs, rc, n0, n1, n2, n3))
            for vs, vc, hole, rb in rings: f.write(struct.pack("<IIBffff", vs, vc, hole, rb[0], rb[1], rb[2], rb[3]))
            for la, lo in verts: f.write(struct.pack("<ii", la, lo))
            for off, cnt in cell_offsets: f.write(struct.pack("<IH", off, cnt))
            f.write(struct.pack("<I", len(cell_lists)))
            for rid in cell_lists: f.write(struct.pack("<H", rid))
            f.write(struct.pack("<I", len(self.names))); f.write(bytes(self.names))
        by_level = {}
        for r in self.regions: by_level[r["level"]] = by_level.get(r["level"], 0) + 1
        print(f"wrote {out}: regions {len(region_recs)} (by level {by_level}) rings {len(rings)} vertices {len(verts)} names {len(self.names)} B total {os.path.getsize(out)/1e6:.2f} MB")

CN_NAMES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cn_names.json")
def load_cn_names():
    """Tools/cn_names.json：adcode → {zh, en, de, zh-Hant}（Claude API 任务 cn-names 生成，人工复核）；没有就空表、app 端回退到中文"""
    try: return json.load(open(CN_NAMES_PATH, encoding="utf-8"))
    except FileNotFoundError: return {}
def cn_names_for(table, adcode, zh_short):
    e = table.get(str(adcode)) or {}
    return {"zh-Hans": zh_short, "en": e.get("en") or "", "de": e.get("de") or e.get("en") or "", "zh-Hant": e.get("zh-Hant") or ""}

def build_real(args):
    b = Builder(args.tolerance_m)
    cn_names = load_cn_names()
    if cn_names: print(f"cn_names.json: {len(cn_names)} entries")
    countries = json.load(open(args.countries, encoding="utf-8"))["features"]
    # 可选：国家多边形换成更高分辨率的源（geoBoundaries CGAZ ADM0，按 ISO3 对上 NE 的属性/名称）；港澳在 CGAZ 里并入中国，保留 NE 的
    alt_geom = {}
    if args.countries_geom:
        for ft in json.load(open(args.countries_geom, encoding="utf-8"))["features"]:
            k = (ft.get("properties") or {}).get("shapeGroup")
            if k and k not in ("HKG", "MAC"): alt_geom[k] = ft["geometry"]
        print(f"alternate country geometry: {len(alt_geom)} ISO3 codes")
        # 属地剔除：CGAZ 的英国/美国/丹麦… 把直布罗陀/关岛/法罗… 并在一起，而 NE 把它们单列（SOV_A3 指向宗主国）。
        # 宗主国的某块多边形若其代表点落在同一 SOV_A3 的另一个 NE 要素里，就从宗主国里去掉，让属地自己的多边形生效
        ne_by_a3 = {}
        for ft in countries:
            p = ft["properties"]; a3 = p.get("ADM0_A3") or p.get("adm0_a3") or ""; sov = p.get("SOV_A3") or p.get("sov_a3") or ""
            outers = [poly[0] for poly in iter_polys(ft["geometry"])]
            if a3 and outers:
                bb = (min(p[1] for r in outers for p in r), min(p[0] for r in outers for p in r), max(p[1] for r in outers for p in r), max(p[0] for r in outers for p in r))
                ne_by_a3[a3] = (sov, outers, sum(ring_area_km2(r) for r in outers), bb)
        def pip(pt, ring):
            x, y = pt; inside = False; j = len(ring) - 1
            for i in range(len(ring)):
                xi, yi = ring[i]; xj, yj = ring[j]
                if (yi > y) != (yj > y) and x < xi + (y - yi) * (xj - xi) / (yj - yi): inside = not inside
                j = i
            return inside
        # 不只是去掉：把这些多边形转给属地自己（CGAZ 比 NE 细得多，NE 的泽西/阿鲁巴轮廓连首府都盖不住）
        moved = {}; dropped = 0
        for a3, geom in list(alt_geom.items()):
            sov = ne_by_a3.get(a3, ("", [], 0, None))[0]
            deps = [(d, rings, darea, dbb) for d, (s2, rings, darea, dbb) in ne_by_a3.items() if d != a3 and s2 == sov and sov]
            if not deps: continue
            keep = []
            for poly in iter_polys(geom):
                outer = poly[0]; parea = ring_area_km2(outer)
                pbb = (min(p[1] for p in outer), min(p[0] for p in outer), max(p[1] for p in outer), max(p[0] for p in outer))
                # 归属判定（面积须和属地同量级，防止以色列整块被挪给巴勒斯坦）：外环顶点多数落在属地的 NE 多边形里，
                # 或者外环的外接框整个落在属地外接框（外扩 0.03°）里——NE 的群岛轮廓很粗，法罗/阿鲁巴靠后一条
                owner = None
                for d, rings, darea, dbb in deps:
                    if parea > 1.5 * max(darea, 1e-3): continue
                    inbox = pbb[0] >= dbb[0] - 0.03 and pbb[1] >= dbb[1] - 0.03 and pbb[2] <= dbb[2] + 0.03 and pbb[3] <= dbb[3] + 0.03
                    step = max(1, len(outer) // 200)
                    sample = outer[::step]
                    frac = sum(1 for pt in sample if any(pip(pt, r) for r in rings)) / len(sample)
                    if frac >= 0.5 or (inbox and frac >= 0.1): owner = d; break
                if owner: dropped += 1; moved.setdefault(owner, []).append([list(map(list, r)) for r in poly]); continue
                keep.append([list(map(list, r)) for r in poly])
            alt_geom[a3] = {"type": "MultiPolygon", "coordinates": keep} if keep else geom
        for d, polys in moved.items():
            # 宗主国里切出来的那块通常比 CGAZ/NE 给属地自己的那份更细（阿鲁巴的 CGAZ 自有多边形连首府都盖不住），一律用它
            alt_geom[d] = {"type": "MultiPolygon", "coordinates": polys}
        print(f"moved {dropped} dependency polygons from sovereigns to {len(moved)} dependencies: {sorted(moved)}")
    replaced = 0
    iso_to_rid, a3_to_rid, iso_seen = {}, {}, {}
    for ft in countries:
        p = ft["properties"]
        def g(*keys):
            for k in keys:
                v = p.get(k) or p.get(k.lower()) or p.get(k.upper())
                if v not in (None, "", "-99"): return v
            return None
        iso = g("ISO_A2_EH", "ISO_A2") or ""              # -99（北塞浦路斯、索马里兰等）→ 没有 ISO：照样收，只是没有国旗
        a3 = g("ADM0_A3", "ADM0_A3_US", "SOV_A3") or ""
        base = g("NAME", "ADMIN") or ""
        names = {"zh-Hans": clean_zh(g("NAME_ZH")) or base, "en": g("NAME_EN") or base, "de": g("NAME_DE") or base, "zh-Hant": g("NAME_ZHT") or g("NAME_ZH") or base}
        names.update(COUNTRY_NAME_OVERRIDE.get(iso, {}))
        geom = ft["geometry"]
        if a3 in alt_geom: geom = alt_geom[a3]; replaced += 1
        rid = b.add(0, None, iso, names, geom, min_ring_km2=1.0, tol_m=args.tolerance_m_l0 if a3 in alt_geom else None)
        if rid is None: continue
        if iso:
            if iso in iso_seen:
                # 同一 ISO 出现两次（NE 偶有）：留面积大的那个挂省/州
                if b.regions[rid]["area"] <= b.regions[iso_seen[iso]]["area"]: print(f"warn: duplicate ISO {iso}, keeping larger"); 
                else: iso_to_rid[iso] = rid; iso_seen[iso] = rid
            else: iso_to_rid[iso] = rid; iso_seen[iso] = rid
        if a3:
            if a3 in a3_to_rid: print(f"warn: duplicate ADM0_A3 {a3} ({names['en']}), admin1 will attach to the first one")
            a3_to_rid.setdefault(a3, rid)
    admin1 = json.load(open(args.admin1, encoding="utf-8"))["features"]
    # 只有一个一级行政区的国家（梵蒂冈等）：那一个单元就是整个国家，而 NE 的小多边形和 CGAZ 国界对不上会留下「其余」，直接不建这一层
    a1_count = {}
    for ft in admin1:
        p = ft["properties"]; a3 = p.get("adm0_a3") or p.get("ADM0_A3") or (p.get("iso_a2") or "")
        a1_count[a3] = a1_count.get(a3, 0) + 1
    cn_prov = {}          # 省 adcode → rid
    cn_by_name = {}
    orphans = 0
    datav_hkmo = set()
    if args.china_dir:
        for code, iso in HKMO.items():
            if os.path.exists(os.path.join(args.china_dir, f"{code}_full.json")): datav_hkmo.add(iso)
    grouped = {}      # (a3, parent rid, 组名) → [feature…]
    def a1_names(p, iso, base):
        zh = clean_zh(p.get("name_zh") or "")
        if base == "(unnamed)": zh = zh or "未命名地区"
        return {"zh-Hans": short_cn(zh, 1) if iso == "CN" and zh else (zh or base), "en": p.get("name_en") or base,
                "de": p.get("name_de") or p.get("name_en") or base,
                "zh-Hant": short_cn(p.get("name_zht") or "", 1) if iso == "CN" and p.get("name_zht") else (p.get("name_zht") or ""),
                "type": p.get("type_en") or p.get("type") or "",
                "alt": p.get("gn_name") or p.get("woe_name") or p.get("name_local") or p.get("iso_3166_2") or ""}
    for ft in admin1:
        p = ft["properties"]
        iso = p.get("iso_a2") or p.get("ISO_A2") or ""
        a3 = p.get("adm0_a3") or p.get("ADM0_A3") or ""
        if iso in datav_hkmo: continue                 # 港澳分区用 DataV 的
        if iso == "CN" and (p.get("name") or "") in ("Paracel Islands",): continue   # NE 把西沙单列为省级；世界迷雾按 31 省，落点算中国直属
        if a1_count.get(a3 or iso, 0) == 1: continue   # 单一一级行政区 = 国家本身
        parent = a3_to_rid.get(a3) if a3 else None
        if parent is None: parent = iso_to_rid.get(iso)
        if parent is None: orphans += 1; continue
        base = p.get("name") or p.get("NAME") or p.get("name_alt") or p.get("woe_name") or p.get("gn_name") or ""
        if not base: base = "(unnamed)"                # NE 少数要素没有任何名字（南极洲地块、争议区）
        if a3 in GROUP_FIELD:                          # 法/意/西/英：先攒起来按大区聚
            grp = p.get(GROUP_FIELD[a3]) or p.get("region") or base
            grouped.setdefault((a3, parent, grp), []).append(ft); continue
        names = a1_names(p, iso, base)
        zh = p.get("name_zh") or ""                    # 后面中国省份按原始 name_zh 匹配 adcode 表
        rid = b.add(1, parent, "", names, ft["geometry"], min_ring_km2=0.2)
        if rid is None: continue
        if iso == "CN":
            code = (p.get("iso_3166_2") or "").upper().replace("CN-", "")
            for adcode, (zhname, alpha, num) in CN_PROVINCES.items():
                if code in (alpha, num) or (zh and norm_cn(zh) == zhname): cn_prov[adcode] = rid
            if zh: cn_by_name[norm_cn(zh)] = rid
    # 法/意/西/英：大区 = 成员省的多边形并列（偶奇规则下相邻省的共享边是零面积缝；高亮按省画），省挂为二级；只有一个省的大区不建二级
    n_groups = 0; n_members = 0; unknown = set()
    for (a3, parent, grp), fts in sorted(grouped.items(), key=lambda kv: (kv[0][0], str(kv[0][2]))):
        key = norm_key(grp)
        zh, en, de = GROUP_NAMES.get(key, (clean_zh(grp), grp, grp))
        if key not in GROUP_NAMES: unknown.add(grp)
        polys = [poly for ft in fts for poly in iter_polys(ft["geometry"])]
        geom = {"type": "MultiPolygon", "coordinates": [[list(map(list, r)) for r in poly] for poly in polys]}
        grid_ = b.add(1, parent, "", {"zh-Hans": zh, "en": en, "de": de, "zh-Hant": to_hant(zh)}, geom, min_ring_km2=0.2)
        if grid_ is None: continue
        n_groups += 1
        if len(fts) > 1:
            for ft in fts:
                p = ft["properties"]; base = p.get("name") or "(unnamed)"
                rid = b.add(2, grid_, "", a1_names(p, p.get("iso_a2") or "", base), ft["geometry"], min_ring_km2=0.2)
                if rid is not None: n_members += 1
    if grouped: print(f"grouped admin1 for FR/IT/ES/GB: {n_groups} regions, {n_members} members as level 2; unknown group names: {sorted(unknown)}")
    print(f"countries {len(iso_to_rid)} (+{sum(1 for r in b.regions if r['level']==0)-len(iso_to_rid)} without ISO; {replaced} with alternate geometry), admin1 orphans {orphans}, CN provinces matched {len(cn_prov)}/31")
    if args.china_dir:
        tf = gcj_to_wgs if args.datav_datum == "gcj02" else None
        total2 = 0; child_area = {}
        for fpath in sorted(glob.glob(os.path.join(args.china_dir, "*_full.json"))):
            m = re.match(r"(\d{6})_full\.json$", os.path.basename(fpath))
            if not m: continue
            fcode = int(m.group(1))
            if fcode == 100000 or fcode not in CN_PROVINCES: continue      # 全国文件 / 港澳台不走这里
            data = json.load(open(fpath, encoding="utf-8"))
            n_added = 0
            for ft in data.get("features", []):
                p = ft.get("properties", {})
                par = p.get("parent") if isinstance(p.get("parent"), dict) else {}
                pcode = par.get("adcode") or ((p.get("acroutes") or [None, None])[1]) or fcode
                try: pcode = int(pcode)
                except (TypeError, ValueError): pcode = fcode
                parent = cn_prov.get(pcode) or cn_by_name.get(CN_PROVINCES.get(pcode, ("",))[0])
                if parent is None: continue
                nm = p.get("name") or ""
                if not nm or p.get("level") not in ("city", "district"): continue
                rid = b.add(2, parent, "", cn_names_for(cn_names, p.get("adcode"), short_cn(nm, 2)), ft["geometry"],
                            min_ring_km2=0.05, tol_m=args.tolerance_m_l2, transform=tf)
                if rid is not None:
                    n_added += 1; child_area[parent] = child_area.get(parent, 0.0) + b.regions[rid]["area"]
            total2 += n_added
            print(f"  {fcode} {CN_PROVINCES[fcode][0]}: {n_added} prefecture-level regions")
            if n_added == 0: raise SystemExit(f"error: {fpath} contributed no city/district features (schema changed? province unmatched?)")
        # 港澳：分区挂为 NE 国家 HK / MO 的一级行政区（世界迷雾也细分到区）
        for code, iso in HKMO.items():
            fpath = os.path.join(args.china_dir, f"{code}_full.json")
            parent = iso_to_rid.get(iso)
            if not os.path.exists(fpath) or parent is None: print(f"  {code} {iso}: skipped (file or NE country missing)"); continue
            n_added = 0; union = []
            for ft in json.load(open(fpath, encoding="utf-8")).get("features", []):
                nm = ft.get("properties", {}).get("name") or ""
                if not nm: continue
                rid = b.add(1, parent, "", cn_names_for(cn_names, ft.get("properties", {}).get("adcode"), nm), ft["geometry"],
                            min_ring_km2=0.02, tol_m=args.tolerance_m_l2, transform=tf)
                if rid is not None: n_added += 1; union.extend(b.regions[rid]["polys"])
            if union:   # 国家轮廓直接用分区的并集（各分区多边形并列；相邻边界重合处偶奇规则下是零面积缝，可忽略）
                b.regions[parent]["polys"] = [[list(ring) for ring in poly] for poly in union]
                b.regions[parent]["area"] = sum(b.regions[r]["area"] for r in range(len(b.regions)) if b.regions[r]["parent"] == parent and b.regions[r]["level"] == 1)
            print(f"  {code} {iso}: {n_added} districts (country outline = union of districts)")
        for prid, a in child_area.items(): b.regions[prid]["area"] = a     # 省面积 = 地级之和（「占本区面积」口径一致）
        missing = [CN_PROVINCES[c][0] for c in CN_PROVINCES if cn_prov.get(c) not in child_area]
        if missing: raise SystemExit(f"error: provinces without prefecture-level children: {missing}")
        if total2 < 400: raise SystemExit(f"error: only {total2} prefecture-level regions built (expected ≈440: 333 地级 + 直辖市/海南的区县)")
    # 同一上级下重名（秘鲁 利马省×2、乌克兰 基辅 市/州…）：简体名后加「（英文名）」区分；繁体名统一半角连字符
    seen = {}
    for r in b.regions:
        n = r["names"]
        if n.get("zh-Hant"): n["zh-Hant"] = n["zh-Hant"].replace("－", "-").replace("—", "-").replace("–", "-")
        seen.setdefault((r["parent"], r["level"], n.get("zh-Hans")), []).append(r)
    TYPE_ZH = {"province": "省", "region": "大区", "city": "市", "oblast": "州", "county": "郡", "district": "区", "municipality": "市", "autonomous region": "自治区",
               "department": "省", "prefecture": "县", "metropolitan city": "广域市", "special city": "特别市", "state": "州", "governorate": "省", "canton": "州",
               "territory": "领地", "capital": "首都", "federal district": "联邦区", "capital city": "首都", "capital district": "首都区", "autonomous city": "自治市",
               "independent city": "直辖市", "captial district": "首都区", "constitutional province": "宪法省", "city with county rights": "市", "voivodeship": "省", "parish": "堂区", "commune": "市镇", "administrative region": "行政区"}
    dups = 0
    for key, rs in seen.items():
        if len(rs) > 1 and key[2]:
            types = [(r["names"].get("type") or "").strip() for r in rs]
            ens = [(r["names"].get("en") or "").strip() for r in rs]
            alts = [(r["names"].get("alt") or "").strip() for r in rs]
            for idx_, (r, t, en, alt) in enumerate(zip(rs, types, ens, alts)):
                if types.count(t) == 1 and t: tag = TYPE_ZH.get(t.lower(), t)                      # 类型能区分：基辅（市）/（大区）
                elif ens.count(en) == 1 and en and en != r["names"]["zh-Hans"]: tag = en              # 英文名能区分
                elif alts.count(alt) == 1 and alt and alt != r["names"]["zh-Hans"]: tag = alt         # GeoNames/本地名能区分（拉脱维亚 20 个「瓦尔米耶拉」）
                else: tag = str(idx_ + 1)                                                             # 实在一样就编号
                r["names"]["zh-Hans"] = f'{r["names"]["zh-Hans"]}（{tag}）'; dups += 1
    if dups: print(f"disambiguated {dups} same-name regions")
    b.write(args.out)

def build_synthetic(out):
    """两个假国家：Alpha（州 A1/A2，A1 下有两个市）、Beta（州 B1）；经纬度 0–4° 附近的矩形"""
    b = Builder(0)
    def rect(lon0, lat0, lon1, lat1): return {"type": "Polygon", "coordinates": [[[lon0, lat0], [lon1, lat0], [lon1, lat1], [lon0, lat1], [lon0, lat0]]]}
    alpha = b.add(0, None, "AA", {"zh-Hans": "阿尔法国", "en": "Alpha", "de": "Alpha", "zh-Hant": "阿爾法國"}, rect(0, 0, 2, 2))
    a1 = b.add(1, alpha, "", {"zh-Hans": "甲州", "en": "A1 State", "de": "A1-Land", "zh-Hant": "甲州"}, rect(0, 0, 1, 2))
    a2 = b.add(1, alpha, "", {"zh-Hans": "乙州", "en": "A2 State", "de": "A2-Land", "zh-Hant": "乙州"}, rect(1, 0, 2, 2))
    b.add(2, a1, "", {"zh-Hans": "甲一市", "en": "A1-1 City", "de": "A1-1", "zh-Hant": "甲一市"}, rect(0, 0, 1, 1))
    b.add(2, a1, "", {"zh-Hans": "甲二市", "en": "A1-2 City", "de": "A1-2", "zh-Hant": "甲二市"}, rect(0, 1, 1, 2))
    beta = b.add(0, None, "BB", {"zh-Hans": "贝塔国", "en": "Beta", "de": "Beta", "zh-Hant": "貝塔國"}, rect(2, 0, 4, 2))
    b.add(1, beta, "", {"zh-Hans": "丙州", "en": "B1 State", "de": "B1-Land", "zh-Hant": "丙州"},
          {"type": "Polygon", "coordinates": [[[2, 0], [4, 0], [4, 2], [2, 2], [2, 0]], [[2.5, 0.5], [3.5, 0.5], [3.5, 1.5], [2.5, 1.5], [2.5, 0.5]]]})   # 带洞
    b.write(out)

def build_synthetic2(out):
    """刁钻几何（给 Tests/probes/regions 用，期望值写在探针里）：
    - CC 国（经 10–14，纬 10–12）：西州 / 东州以 12°E 为界，但东州在 (11.000–11.004, 11.996–12.000) 有一块凸进西州的舌头；
      西州里有一块 0.003° 的飞地州「飞地」(10.500–10.503)；东州由两块组成，中间夹着 200 m 宽的「窄条州」(13.000–13.002)；
    - DD 国：海上小岛 (10.003–10.007, 15.003–15.007)，避开 0.01° 单元的中心和四角；
    - EE 国：跨日界线两块（178–180 与 −180–−178，纬 50–52）；
    - II 国（经 12–14，纬 41–43）带洞 + 洞里的微型国 VV (41.900–41.906, 12.450–12.456)，II 的州「拉州」同样带洞；
    - FF 国（经 20–21.5）与 GG 国（21.5–23），GG 的州「越界州」多边形伸到 21.4（FF 境内）——跨国格里要按国家多边形裁决。"""
    b = Builder(0)
    def rect(lon0, lat0, lon1, lat1): return [[lon0, lat0], [lon1, lat0], [lon1, lat1], [lon0, lat1], [lon0, lat0]]
    def poly(*rings): return {"type": "Polygon", "coordinates": list(rings)}
    def multi(*polys): return {"type": "MultiPolygon", "coordinates": [p["coordinates"] for p in polys]}
    N = lambda zh, en: {"zh-Hans": zh, "en": en, "de": en, "zh-Hant": zh}
    cc = b.add(0, None, "CC", N("丙国", "Gamma"), poly(rect(10, 10, 14, 12)))
    tongue = [[12, 11.0], [11.996, 11.0], [11.996, 11.004], [12, 11.004]]
    west = [[10, 10], [12, 10]] + tongue + [[12, 12], [10, 12], [10, 10]]
    b.add(1, cc, "", N("西州", "West"), poly(west, rect(10.5, 10.5, 10.503, 10.503)))
    east_a = [[12, 10], [13, 10], [13, 12], [12, 12], [12, 11.004], [11.996, 11.004], [11.996, 11.0], [12, 11.0], [12, 10]]
    b.add(1, cc, "", N("东州", "East"), multi(poly(east_a), poly(rect(13.002, 10, 14, 12))))
    b.add(1, cc, "", N("飞地", "Enclave"), poly(rect(10.5, 10.5, 10.503, 10.503)))
    b.add(1, cc, "", N("窄条州", "Strip"), poly(rect(13.0, 10, 13.002, 12)))
    b.add(0, None, "DD", N("丁国", "Delta"), poly(rect(15.003, 10.003, 15.007, 10.007)))
    b.add(0, None, "EE", N("戊国", "Epsilon"), multi(poly(rect(178, 50, 180, 52)), poly(rect(-180, 50, -178, 52))))
    ii = b.add(0, None, "II", N("意国", "Ital"), poly(rect(12, 41, 14, 43), rect(12.45, 41.9, 12.456, 41.906)))
    b.add(1, ii, "", N("拉州", "Lazio"), poly(rect(12, 41, 14, 43), rect(12.45, 41.9, 12.456, 41.906)))
    b.add(0, None, "VV", N("梵国", "Vatic"), poly(rect(12.45, 41.9, 12.456, 41.906)))
    ff = b.add(0, None, "FF", N("己国", "Foxtrot"), poly(rect(20, 30, 21.5, 31)))
    b.add(1, ff, "", N("己州", "F-State"), poly(rect(20, 30, 21.5, 31)))
    gg = b.add(0, None, "GG", N("庚国", "Golf"), poly(rect(21.5, 30, 23, 31)))
    b.add(1, gg, "", N("越界州", "Overhang"), poly(rect(21.4, 30, 22.5, 31)))
    b.add(1, ff, "", N("海岸州", "Coast"), poly(rect(19.9, 30.4, 20.0, 30.6)))      # 只被州包含、不被任何国家包含的填海带（跨国格）→ 退回州
    # HH 国：2600 顶点的近圆环（圆心 25°E 35°N，半径 1°，带微小起伏）+ 一个方洞 → 触发大环的纬度分带边索引
    ring = [[25 + math.cos(2 * math.pi * i / 2600) * (1 + 0.02 * math.sin(40 * 2 * math.pi * i / 2600)),
             35 + math.sin(2 * math.pi * i / 2600) * (1 + 0.02 * math.sin(40 * 2 * math.pi * i / 2600))] for i in range(2600)]
    ring.append(ring[0])
    b.add(0, None, "HH", N("辛国", "Hotel"), poly(ring, rect(25.2, 35.2, 25.3, 35.3)))
    # JJ 国（经 40–42）：唯一的州只盖到 41.98，东边 0.02° 是国界与州界之间的缝 → 缝里的点吸附到最近的州（≤3 km）
    jj = b.add(0, None, "JJ", N("壬国", "Juliett"), poly(rect(40, 10, 42, 12)))
    b.add(1, jj, "", N("壬州", "J-State"), poly(rect(40, 10, 41.98, 12)))
    b.add(1, jj, "", N("壬二州", "J-State-2"), poly(rect(40, 12, 42, 12.5)))     # 另一个州在北边，离缝更远
    # KK 国（经 44–46）里套着属地 LL（44.5–44.6，没挖洞）：同级面积小的先命中 → 属地赢
    b.add(0, None, "KK", N("癸国", "Kilo"), poly(rect(44, 10, 46, 12)))
    b.add(0, None, "LL", N("属地", "Lima"), poly(rect(44.5, 10.5, 44.6, 10.6)))
    # MM 国（经 48–50）在 NN 国（经 50–52）里有一块飞地（50.3–50.31），NN 没挖洞：按「包含该点的最小外环」判给 MM（坎皮奥内式）
    b.add(0, None, "MM", N("飞地国", "Mike"), multi(poly(rect(48, 10, 50, 12)), poly(rect(50.3, 10.3, 50.31, 10.31))))
    b.add(0, None, "NN", N("邻国", "November"), poly(rect(50, 10, 52, 12)))
    b.write(out)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--countries"); ap.add_argument("--admin1"); ap.add_argument("--china-dir"); ap.add_argument("--out")
    ap.add_argument("--tolerance-m", type=float, default=150); ap.add_argument("--tolerance-m-l2", type=float, default=50)
    ap.add_argument("--countries-geom", help="geoBoundaries CGAZ ADM0 GeoJSON：国家多边形换成它（NE 只出属性/名称）")
    ap.add_argument("--tolerance-m-l0", type=float, default=None, help="换源的国家多边形的简化容差（默认同 --tolerance-m）")
    ap.add_argument("--datav-datum", choices=["gcj02", "wgs84"], default="gcj02")
    ap.add_argument("--synthetic"); ap.add_argument("--synthetic2")
    a = ap.parse_args()
    if a.synthetic: build_synthetic(a.synthetic)
    elif a.synthetic2: build_synthetic2(a.synthetic2)
    else:
        if not (a.countries and a.admin1 and a.out): ap.error("--countries --admin1 --out are required")
        build_real(a)
