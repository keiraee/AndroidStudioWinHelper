class MirrorSource {
  final String name;
  final String host;
  final String mavenUrl;
  final String? googleUrl;

  const MirrorSource({required this.name, required this.host, required this.mavenUrl, this.googleUrl});

  static const List<MirrorSource> builtIn = [
    MirrorSource(name: '阿里云', host: 'maven.aliyun.com', mavenUrl: 'https://maven.aliyun.com/repository/public', googleUrl: 'https://maven.aliyun.com/repository/google'),
    MirrorSource(name: '腾讯云', host: 'mirrors.cloud.tencent.com', mavenUrl: 'https://mirrors.cloud.tencent.com/nexus/repository/maven-public'),
    MirrorSource(name: '华为云', host: 'repo.huaweicloud.com', mavenUrl: 'https://repo.huaweicloud.com/repository/maven'),
    MirrorSource(name: '中科大', host: 'mirrors.ustc.edu.cn', mavenUrl: 'https://mirrors.ustc.edu.cn/maven'),
    MirrorSource(name: '清华', host: 'mirrors.tuna.tsinghua.edu.cn', mavenUrl: 'https://mirrors.tuna.tsinghua.edu.cn/maven'),
  ];
}

class MirrorTestResult {
  final MirrorSource source;
  final bool reachable;
  final int? latencyMs;
  const MirrorTestResult({required this.source, required this.reachable, this.latencyMs});
}
