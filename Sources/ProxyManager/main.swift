import Foundation

// Headless hooks for testing / scripting, evaluated before the GUI starts.
let args = CommandLine.arguments

if args.contains("--print-caddyfile") {
    print(CaddyfileBuilder.build(HostStore.load()))
    exit(0)
}

if args.contains("--selftest") {
    // Build a representative config that exercises every Caddyfile feature.
    var cfg = AppConfig()
    cfg.settings.acmeEmail = "admin@example.com"
    cfg.settings.useStagingCA = true

    var local = ProxyHost()
    local.domains = ["app.example.com"]
    local.upstreamHost = "localhost"
    local.upstreamPort = 3000

    var unifi = ProxyHost()
    unifi.domains = ["unifi.example.com", "udm.example.com"]
    unifi.upstreamScheme = .https
    unifi.upstreamHost = "192.168.1.10"
    unifi.upstreamPort = 443
    unifi.skipTLSVerify = true
    unifi.basicAuth = BasicAuth(username: "timo",
                                bcryptHash: "$2a$14$Zkx19XLiW6VYouLHR5NmfOFU0z2GTNmpkT/5qqR7hx4IjWJPDhjvG")
    unifi.basicAuthSkipInternal = true
    unifi.allowCIDRs = ["192.168.0.0/16", "10.0.0.0/8"]
    unifi.denyCIDRs = ["192.168.1.66/32"]

    var page = ProxyHost()
    page.domains = ["status.example.com"]
    page.target = .staticPage
    page.staticContent = "<h1>OK</h1>"

    cfg.hosts = [local, unifi, page]
    print(CaddyfileBuilder.build(cfg))
    exit(0)
}

ProxyManagerApp.main()
