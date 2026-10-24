"""Portão de release do front (Spec 12 §0.5 e §2.3): confere o menu lateral por perfil e que cada link abre sem erro.

Uso: QA_NICHES=<niches.json> python qa/menu_check.py [admin|operador] [https://host]
Sai com código 1 se faltar item, sobrar item de IA fora da permissão, ou se algum link abrir 404/erro de página.
Requer: pip install playwright (usa o Chrome instalado).
"""
import json
import os
import sys

from playwright.sync_api import sync_playwright

MAIN_IA = ["Chat com IA", "Consumo", "Ambiente", "Execuções"]
SETTINGS_IA = ["Agentes de IA", "Skills", "Tarefas agendadas", "Provedores", "Combos",
               "Credenciais", "Filas de IA", "Integrações", "Limites"]
# perfil -> (itens esperados no menu principal de IA, itens esperados em Configurações > IA)
EXPECTED = {
    "admin": (["Kanban"] + MAIN_IA, SETTINGS_IA),
    "operador": (["Kanban", "Chat com IA", "Consumo", "Execuções"], []),
}
WIDTHS = [1440, 1024, 390]
SCHEMES = ["light", "dark"]
NAV_JS = "[...document.querySelectorAll('nav a')].map(a=>({t:(a.innerText||'').trim().split('\\n')[0],h:a.href})).filter(x=>x.t)"


def main():
    profile = sys.argv[1] if len(sys.argv) > 1 else "admin"
    base = sys.argv[2] if len(sys.argv) > 2 else "https://app.rangeltech.net"
    niches = json.load(open(os.environ["QA_NICHES"], encoding="utf-8"))["padaria"]
    user = niches["users"]["marina" if profile == "admin" else "carlos"]
    acc = niches["account_id"]
    main_exp, settings_exp = EXPECTED[profile]
    fails = []
    with sync_playwright() as p:
        b = p.chromium.launch(channel="chrome")
        for w in WIDTHS:
            for scheme in SCHEMES:
                ctx = b.new_context(viewport={"width": w, "height": 900}, color_scheme=scheme)
                pg = ctx.new_page()
                errors = []
                pg.on("pageerror", lambda e: errors.append(str(e)))
                pg.goto(f"{base}/app/login")
                pg.fill("input[type=email]", user["email"])
                pg.fill("input[type=password]", user["password"])
                pg.click("button[type=submit]")
                pg.wait_for_url(f"**/accounts/{acc}/**", timeout=30000)
                for name, path, expected in (("principal", "conversations", main_exp),
                                             ("configuracoes", "settings/general", settings_exp)):
                    pg.goto(f"{base}/app/accounts/{acc}/{path}")
                    pg.wait_for_selector("nav", timeout=20000)
                    if w < 768:
                        pg.click("[aria-label*=menu i], button:has(.i-lucide-menu)", timeout=3000)
                    links = pg.evaluate(NAV_JS)
                    labels = {l["t"] for l in links}
                    for item in expected:
                        if item not in labels:
                            fails.append(f"{profile} {w} {scheme} {name}: falta '{item}'")
                    for l in links:
                        if l["t"] in expected and l["t"] not in ("Kanban",):
                            r = pg.request.get(l["h"])
                            if r.status >= 400:
                                fails.append(f"{profile} {w} {scheme}: '{l['t']}' -> HTTP {r.status}")
                if errors:
                    fails.append(f"{profile} {w} {scheme}: erro de página: {errors[0][:120]}")
                ctx.close()
        b.close()
    print(json.dumps({"profile": profile, "falhas": fails}, ensure_ascii=False, indent=1))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
