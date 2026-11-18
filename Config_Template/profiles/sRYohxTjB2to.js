// =====================================================================
// Clash Verge 增强脚本 —— 「钉死单个节点 · 零回落直连」严格版 v10
//
// 设计目标（只允许断开，不允许回落直连）：
//   1. 整个配置里只保留 1 个节点（默认 V3-【双ISP家庭网络】韩国，可在「Claude 保护」里切换）。
//      其余节点、自动选择、测速组一律删除，界面上无法误切到别的出口；锁定的节点不在订阅里 = 全断。
//   2. 规则只有：局域网直连 / 白羊订阅 API 域名直连(仅用于入口端口变更后的自愈) /
//      国内开发镜像主机直连(Docker/npm/Maven/pip/apt，精确主机名白名单) / 腾讯云直连 /
//      屏蔽 QUIC / 其余一律 KR-ONLY。没有 GEOIP CN，没有国内直连名单，没有 DIRECT 兜底。
//   3. DNS 全部走 fake-ip；真实解析通过 KR-ONLY 内的 DoH，不向国内/运营商明文查询。
//      只有解析中继域名本身（proxy-server-nameserver）走国内 DoH（IP 直连、加密），
//      运营商看不到明文查询，也无法篡改解析结果。
//   4. 关闭 IPv6、NTP 自校时、sniffer、hosts 覆盖，避免任何旁路。
//   5. TUN 的 enable / mtu / strict-route 最终以 Verge 的 verge.yaml + config.yaml
//      为准（Verge 会在本脚本之后覆盖），本脚本写一份用于单独编译时保持一致。
// =====================================================================
function main(config, profileName) {
  // 策略组名固定为 KR-ONLY（守护按此名称校验），实际锁定哪个节点由下面两行决定。
  var GROUP = 'KR-ONLY';
  // 「Claude 保护」切换锁定节点时会改写这两行；默认 = 韩国双 ISP
  var PIN_NAME = 'V3-【双ISP家庭网络】韩国🇰🇷';
  var PIN_FUZZY = ['双ISP', '韩国'];   // 精确名称找不到时的备用匹配（需包含全部关键字）；空数组 = 只认精确名称

  // ---------- 1. 只保留锁定的那一个节点 ----------
  var all = Array.isArray(config.proxies) ? config.proxies : [];
  var candidates = all.filter(function (p) {
    if (!p || !p.name || !p.server) return false;
    var server = String(p.server).trim();
    return server.indexOf('127.') !== 0 && server !== 'localhost';
  });
  var pinned = null;
  for (var i = 0; i < candidates.length; i++) {
    if (candidates[i].name === PIN_NAME) { pinned = candidates[i]; break; }
  }
  if (!pinned && PIN_FUZZY.length > 0) {
    for (var j = 0; j < candidates.length && !pinned; j++) {
      var nm = String(candidates[j].name), hit = true;
      for (var k = 0; k < PIN_FUZZY.length; k++) { if (nm.indexOf(PIN_FUZZY[k]) === -1) { hit = false; break; } }
      if (hit) pinned = candidates[j];
    }
  }

  var rules;
  if (pinned) {
    pinned.udp = true;
    config.proxies = [pinned];
    config['proxy-groups'] = [{ name: GROUP, type: 'select', proxies: [pinned.name] }];
    rules = [
      // 局域网（不会出境）
      'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
      'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
      'IP-CIDR,169.254.0.0/16,DIRECT,no-resolve',
      'IP-CIDR,224.0.0.0/4,DIRECT,no-resolve',
      'IP-CIDR,255.255.255.255/32,DIRECT,no-resolve',
      // 订阅自愈：仅白羊订阅 API 域名 + 官方镜像发现地址直连。中继入口端口变化导致节点不通时，
      // 仍能拉到新订阅自动恢复，避免“节点不通→拉不到订阅”的死循环。不涉及 Claude 流量。
      'DOMAIN-SUFFIX,baiyang888.xyz,DIRECT',
      'DOMAIN-SUFFIX,czzpp.cn,DIRECT',
      'DOMAIN-SUFFIX,j396.com,DIRECT',
      'DOMAIN-SUFFIX,smirsb.cn,DIRECT',
      'DOMAIN,byang.oss-ap-southeast-1.aliyuncs.com,DIRECT',
      // 开发镜像白名单：仅国内 Docker / npm / Maven / pip / apt 镜像主机直连（与 Claude 无关）。
      // 只写具体主机，不写 aliyun.com 这类大后缀，也不放任何通用代理（如 GitHub 加速）。
      'DOMAIN-SUFFIX,m.daocloud.io,DIRECT',
      'DOMAIN-SUFFIX,1ms.run,DIRECT',
      'DOMAIN,ccr.ccs.tencentyun.com,DIRECT',
      'DOMAIN,mirror.ccs.tencentyun.com,DIRECT',
      'DOMAIN,registry.npmmirror.com,DIRECT',
      'DOMAIN,cdn.npmmirror.com,DIRECT',
      'DOMAIN,maven.aliyun.com,DIRECT',
      'DOMAIN,mirrors.aliyun.com,DIRECT',
      // 腾讯云：锁定节点连不上腾讯云，只放行腾讯云本身直连（QQ / QQ 邮箱照旧走节点）
      'DOMAIN-SUFFIX,cloud.tencent.com,DIRECT',
      'DOMAIN-SUFFIX,qcloud.com,DIRECT',
      'DOMAIN-SUFFIX,qcloudimg.com,DIRECT',
      'DOMAIN-SUFFIX,myqcloud.com,DIRECT',
      'DOMAIN-SUFFIX,tencentcloudapi.com,DIRECT',
      'DOMAIN-SUFFIX,tencent-cloud.com,DIRECT',
      'DOMAIN-SUFFIX,tencent-cloud.net,DIRECT',
      'DOMAIN-SUFFIX,tencent-cloud.cn,DIRECT',
      // 屏蔽 QUIC：节点是 VLESS over TCP，QUIC 塞进 TCP 隧道遇丢包会严重卡顿；
      // 拒绝后浏览器/Electron 立即改走 HTTP/2(TCP)，首屏与长连接都更稳更快
      'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT',
      // 纯遥测/广告（绝不含 statsig，它是 Claude 登录鉴权所需）
      'DOMAIN-SUFFIX,datadoghq.com,REJECT',
      'DOMAIN-SUFFIX,segment.io,REJECT',
      'DOMAIN-SUFFIX,cdn.usefathom.com,REJECT',
      // 其余全部走锁定的节点；节点不通就是断网，不回落
      'MATCH,' + GROUP
    ];
  } else {
    // 找不到锁定的节点：宁可全断，也不换别的出口
    config.proxies = [];
    config['proxy-groups'] = [];
    rules = [
      'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
      'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
      'MATCH,REJECT'
    ];
  }
  config.rules = rules;
  delete config['proxy-providers'];
  delete config['rule-providers'];
  delete config['listeners'];

  // ---------- 2. DNS：fake-ip + 经 KR-ONLY 的 DoH ----------
  config.dns = {
    enable: true,
    listen: '127.0.0.1:1053',
    ipv6: false,
    'prefer-h3': false,
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    'fake-ip-filter-mode': 'blacklist',
    'fake-ip-filter': [
      '*.lan', '*.local', '*.localhost', '*.arpa', '*.test',
      '+.msftconnecttest.com', '+.msftncsi.com'
    ],
    'respect-rules': false,
    'use-hosts': false,
    'use-system-hosts': false,
    // 入口用域名自动跟随；内核用 IP 形式 DoH 直连解析中继域名（加密，防火墙不放行明文 53）
    'default-nameserver': ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query'],
    'proxy-server-nameserver': ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query'],
    'direct-nameserver': ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query'],
    // 真实解析走韩国节点内的 DoH，不向本地运营商泄露 Claude 域名
    nameserver: [
      'https://1.1.1.1/dns-query#' + GROUP,
      'https://8.8.8.8/dns-query#' + GROUP
    ]
  };

  // ---------- 3. 全局开关 ----------
  config.mode = 'rule';
  config.ipv6 = false;
  config.hosts = {};
  config['allow-lan'] = false;
  config['bind-address'] = '127.0.0.1';
  config['tcp-concurrent'] = true;
  config['unified-delay'] = true;
  config['keep-alive-idle'] = 30;
  config['keep-alive-interval'] = 15;
  config['find-process-mode'] = 'off';
  config['log-level'] = 'warning';
  config['profile'] = { 'store-selected': true, 'store-fake-ip': false };
  config.sniffer = { enable: false };
  config.ntp = { enable: false };

  // ---------- 4. TUN（最终以 Verge 的 config.yaml 为准）----------
  config.tun = {
    enable: true,
    stack: 'mixed',
    mtu: 1360,
    'auto-route': true,
    'auto-detect-interface': true,
    'dns-hijack': ['any:53', 'tcp://any:53'],
    'strict-route': true,
    'route-exclude-address': []
  };

  return config;
}
