import XCTest
@testable import FamilyCore

/// The fixtures are excerpts (shortened descriptions, images and agency details) of real listing pages read
/// on 2026-10-03: the markup, quoting, escaping and field shapes are the portals' own.
final class ListingPageParserTests: XCTestCase {
    private let imovirtual = #"""
<html><head>
<title data-next-head="">T3, apartamento para comprar - Rua 14 de Junho, São Domingos de Rana - 19297167 • www.imovirtual.com</title>
<meta property="og:site_name" content="www.imovirtual.com/" data-next-head=""/>
<meta property="og:title" content="T3, apartamento para comprar - Rua 14 de Junho, São Domingos de Rana - 19297167 • www.imovirtual.com" data-next-head=""/>
<meta name="description" content="Excelente apartamento para venda com T3 em Rua 14 de Junho, São Domingos de Rana, por 635 000 €. Este apartamento para venda localizado no 1 piso tem 118 m² de àrea útil e 118 m² de àrea bruta.Imovirtual 19297167" data-next-head=""/>
<meta property="og:description" content="Excelente apartamento para venda com T3 em Rua 14 de Junho, São Domingos de Rana, por 635 000 €. Este apartamento para venda localizado no 1 piso tem 118 m² de àrea útil e 118 m² de àrea bruta.Imovirtual 19297167" data-next-head=""/>
<script type="application/ld+json">{"@context": "https://schema.org", "@graph": [{"@type": "WebPage", "url": "https://www.imovirtual.com", "name": "T3, apartamento para comprar - Rua 14 de Junho, São Domingos de Rana - 19297167 • www.imovirtual.com", "description": "Excelente apartamento para venda com T3 em Rua 14 de Junho, São Domingos de Rana, por 635 000 €. Este apartamento para venda localizado no 1 piso tem 118 m² de àrea útil e 118 m² de àrea bruta.Imovirtual 19297167", "headline": "Apartamento T3 para venda"}, {"@type": ["Product", "Apartment"], "name": "Apartamento T3 para venda", "url": "https://www.imovirtual.com/pt/anuncio/apartamento-t3-para-venda-ID1iY4D", "description": "<strong>T3 Modernizado com Terraço de 100 m² e Garagem para 3 Carros.  </strong>   <br><br>Cabeço de Mouro, São Domingos de Rana | Cascais&nbsp;<br/>\nHá casas que se destacam pelo espaço.&nbsp;<br/>\nOutras pelo conforto.&nbsp;<br/>\nEsta destaca-se pelos dois.&nbsp;<br/>\nApresento-lhe este apartamento T3, modernizado há cerca de três anos, onde cada detalhe foi pensado para proporcionar funcionalidade e bem-estar no dia a dia.<br>&nbsp;&nbsp;<br/>\nComposto por:&nbsp;<br/>\nSala ampla e luminosa junta com cozinha moderna e atual.&nbsp;<br/>\n3 quartos, sendo um deles suite.&nbsp;<br/>\n2 casas de banho.<br/>\nNo exterior encontra um verdadeiro diferencial:&nbsp;<br/>\nTerraço com cerca de 100 m², com logradouro fechado, perfeito para aproveitar todo o ano, mesmo nos dias menos soalheiros.&nbsp;<br/>\nE a garagem?<br><br>Um ponto raríssimo na zona:&nbsp;<br/>\nEspaço para 2/3 viaturas&nbsp;<br/>\nÁgua e luz.&nbsp;<br/>\nCarregamento para carros eléctricos.&nbsp;<br/>\nParqueamento adicional fechado.<br>&nbsp;&nbsp;<br/>\nO prédio dispõe ainda de painéis solares, reforçando a eficiência energética.&nbsp;<br/>\nValor de condomínio: apenas 30€/mês.<br>&nbsp;&nbsp;<br/>\nEm termos de localização:&nbsp;<br/>\nAcesso à A5 a apenas 2 minutos.&nbsp;<br/>\nComércio, supermercados e serviços nas imediações.&nbsp;<br/>\nVárias escolas de referência na envolvente.<br>&nbsp;&nbsp;<br/>\nUma oportunidade ideal para quem procura espaço exterior, garagem generosa e proximidade a tudo, numa zona consolidada e tranquila.&nbsp;<br/>\nAgende a sua visita.&nbsp;&nbsp;<br/>", "image": "https://example-cdn.test/photo.jpg", "address": {"@type": "PostalAddress", "addressCountry": "Portugal", "addressLocality": "São Domingos de Rana", "addressRegion": "Lisboa", "streetAddress": "Rua 14 de Junho"}, "geo": {"@type": "GeoCoordinates", "latitude": 38.71598, "longitude": -9.331787}, "additionalProperty": [{"@type": "PropertyValue", "name": "Área", "value": "118 m²"}, {"@type": "PropertyValue", "name": "Tipologia", "value": "T3"}, {"@type": "PropertyValue", "name": "N.º de casas de banho", "value": "2 "}, {"@type": "PropertyValue", "name": "Andar", "value": "1/1"}, {"@type": "PropertyValue", "name": "Nova construção", "value": "não"}, {"@type": "PropertyValue", "name": "Tipo de anunciante", "value": "profissional"}, {"@type": "PropertyValue", "name": "Ano de construção", "value": "1997"}, {"@type": "PropertyValue", "name": "Tipo de imóvel", "value": "bloco de apartamentos"}, {"@type": "PropertyValue", "name": "Certificado energético", "value": "C"}], "numberOfRooms": 4, "offers": {"@type": "Offer", "priceCurrency": "EUR", "price": 635000, "priceSpecification": {"@type": "UnitPriceSpecification", "price": 5381.36, "priceCurrency": "EUR", "unitCode": "MTK", "unitText": "square meter"}, "availability": "https://schema.org/InStock", "seller": {"@type": "Organization", "name": "Remax Grupo Team", "url": "/pt/empresas/x", "brand": "Remax Grupo Team", "address": {"@type": "PostalAddress", "streetAddress": "Avenida da Agência, 1"}}}}]}</script>
</head><body></body></html>
"""#

    private let casaSapo = #"""
<html><head>
<title>Apartamento T2 Venda 650.000 € em Lisboa, Marvila - CASA SAPO - Portal Nacional de Imobiliário</title>
<meta name="description" content="apartamento T2 venda 650.000 € em lisboa, marvila - Apartamento T2 com 90 m2, varanda de 11m2 e 1 lugar de estacionamento, inserido no novo condom&#237;nio privado a nascer no vibrante bairro ribeirinho de Marvila, atualmente uma das zonas com mais din&#226;mica e maior crescimento, em Lisboa.  Assinado pelo atelier Appleton &amp; Domingos, apresenta uma abordagem inovadora &#224; vida urbana, onde a natureza, a cultura e o esp&#237;rito de comunidade se entrela&#231;am num ambiente de inspira&#" />
<meta property="og:description" content="Apartamento T2 com 90 m2, varanda de 11m2 e 1 lugar de estacionamento, inserido no novo condomínio privado a nascer no vibrante bairro ribeirinho de Marvila, atualmente uma das zonas com mais dinâmica e maior crescimento, em Lisboa.  Assinado pelo atelier Appleton & Domingos, apresenta uma abordagem inovadora à vida urbana, onde a natureza, a cultura e o espírito de comunidade se entrelaçam num ambiente de inspiração industrial, com vista para o rio Tejo.  Composto por quatro edifícios, um condo" />
<meta property="og:site_name" content="CASA SAPO - Portal Nacional de Imobiliário" />
<meta property="og:title" content="Apartamento T2 Venda 650.000 € em Lisboa, Marvila - CASA SAPO - Portal Nacional de Imobiliário" />
</head><body>
<script type='application/ld&#x2B;json'>
{"@context": "http://schema.org", "@type": "Offer", "image": "https://example-cdn.test/photo.jpg", "name": "Apartamento T2 Marvila, Lisboa", "category": "Apartamentos", "description": "Apartamento T2 com 90 m2, varanda de 11m2 e 1 lugar de estacionamento, inserido no novo condomínio privado a nascer no vibrante bairro ribeirinho de Marvila, atualmente uma das zonas com mais dinâmica e maior crescimento, em (...)", "price": ["650.000 €"], "priceCurrency": ["€"], "availableAtOrFrom": {"@type": "Place", "address": {"addressCountry": "PT", "addressLocality": "Lisboa", "addressRegion": "Marvila"}, "geo": {"@type": "GeoCoordinates", "latitude": 38.74703, "longitude": -9.10146}}, "seller": {"@context": "http://schema.org", "@type": "RealEstateAgent", "name": "Dils Portugal", "image": "https://example-cdn.test/logo.png", "url": "http://dils.pt", "address": {"@type": "PostalAddress", "streetAddress": "Avenida da República, 5 – 2º Piso"}, "telephone": "0", "priceRange": "0"}}
</script>
</body></html>
"""#

    func testImovirtual() {
        let draft = ListingPageParser.parse(html: imovirtual)
        XCTAssertEqual(draft.title, "T3, apartamento para comprar - Rua 14 de Junho, São Domingos de Rana - 19297167", "site name stripped")
        XCTAssertEqual(draft.priceMinor, 63_500_000, "Offer price, not the 5381.36 per m² of the nested price specification")
        XCTAssertEqual(draft.areaM2, 118)
        XCTAssertEqual(draft.rooms, 3, "T3 means 3 bedrooms; numberOfRooms says 4")
        XCTAssertEqual(draft.address, "Rua 14 de Junho, São Domingos de Rana, Lisboa", "the property's address, not the agency's")
        XCTAssertEqual(draft.latitude ?? 0, 38.71598, accuracy: 1e-6)
        XCTAssertEqual(draft.longitude ?? 0, -9.331787, accuracy: 1e-6)
        XCTAssertEqual(draft.imageURL?.scheme, "https")
    }

    func testCasaSapo() {
        let draft = ListingPageParser.parse(html: casaSapo)
        XCTAssertEqual(draft.title, "Apartamento T2 Venda 650.000 € em Lisboa, Marvila")
        XCTAssertEqual(draft.priceMinor, 65_000_000, "price is the array [\"650.000 €\"] with a euro symbol as currency")
        XCTAssertEqual(draft.areaM2, 90, "from the text: the first area, not the 11m2 balcony")
        XCTAssertEqual(draft.rooms, 2)
        XCTAssertEqual(draft.address, "Lisboa, Marvila", "not the agency's street")
        XCTAssertEqual(draft.latitude ?? 0, 38.74703, accuracy: 1e-6)
        XCTAssertEqual(draft.longitude ?? 0, -9.10146, accuracy: 1e-6)
    }

    func testOpenGraphOnlyPage() {
        let html = """
        <html><head><title>Moradia T4 em Braga</title>
        <meta property="og:title" content="Moradia T4 &amp; jardim - Braga" />
        <meta property="og:description" content="Moradia com 210,5 m² de área, à venda por 1.250.000 €." />
        <meta property="product:price:amount" content="1250000" /><meta property="product:price:currency" content="EUR" />
        <meta name="geo.position" content="41.5503;-8.4201" />
        </head></html>
        """
        let draft = ListingPageParser.parse(html: html)
        XCTAssertEqual(draft.title, "Moradia T4 & jardim - Braga")
        XCTAssertEqual(draft.priceMinor, 125_000_000)
        XCTAssertEqual(draft.areaM2, Decimal(string: "210.5"))
        XCTAssertEqual(draft.rooms, 4)
        XCTAssertEqual(draft.latitude ?? 0, 41.5503, accuracy: 1e-6)
    }

    func testPriceTextFormats() {
        XCTAssertEqual(ListingPageParser.priceFromText("por 635 000 € em Lisboa"), 63_500_000)
        XCTAssertEqual(ListingPageParser.priceFromText("635\u{00A0}000\u{00A0}€"), 63_500_000)
        XCTAssertEqual(ListingPageParser.priceFromText("€ 1.250.000"), 125_000_000)
        XCTAssertEqual(ListingPageParser.priceFromText("650.000,50 €"), 65_000_050)
        XCTAssertEqual(ListingPageParser.priceFromText("250.000€"), 25_000_000)
        XCTAssertEqual(ListingPageParser.priceFromText("T2 250.000 €"), 25_000_000, "the 2 of T2 is not part of the price")
        XCTAssertNil(ListingPageParser.priceFromText("sem preço, 75 m²"))
        XCTAssertEqual(ListingPageParser.priceFromText("2.500 €/m², total 450.000 €"), 45_000_000, "a price per m² is skipped")
        XCTAssertNil(ListingPageParser.priceFromText("2.500 €/m2"))
        XCTAssertEqual(ListingPageParser.priceFromText("€ 450.000 (€ 2.500/m²)"), 45_000_000)
    }

    func testForeignCurrencyAndNonsenseAreIgnored() {
        let html = #"<script type="application/ld+json">{"@type":"Offer","name":"x","price":"500000","priceCurrency":"USD"}</script>"#
        XCTAssertNil(ListingPageParser.parse(html: html).priceMinor)
        let broken = #"<script type="application/ld+json">{not json</script><meta property="og:title" content="ok">"#
        XCTAssertEqual(ListingPageParser.parse(html: broken).title, "ok")
        XCTAssertTrue(ListingPageParser.parse(html: "<html></html>").isEmpty)
        XCTAssertTrue(ListingPageParser.parse(html: "").isEmpty)
        let nowhere = #"<meta name="geo.position" content="0;0">"#
        XCTAssertNil(ListingPageParser.parse(html: nowhere).latitude, "0,0 is a missing value, not a place")
    }

    func testAreaAndTypology() {
        XCTAssertEqual(ListingPageParser.areaFromText("T2 com 90 m2, varanda de 11m2"), 90)
        XCTAssertEqual(ListingPageParser.areaFromText("área 75,5 m²"), Decimal(string: "75.5"))
        XCTAssertNil(ListingPageParser.areaFromText("1 m²"), "below 5 m² is noise")
        XCTAssertEqual(ListingPageParser.typology(in: "Apartamento T3 para venda"), 3)
        XCTAssertEqual(ListingPageParser.typology(in: "T0 no centro"), 0)
        XCTAssertEqual(ListingPageParser.typology(in: "3 quartos"), 3)
        XCTAssertNil(ListingPageParser.typology(in: "STUDIO2 UNIT3"))
    }

    func testEntities() {
        XCTAssertEqual(ListingPageParser.decode("condom&#237;nio &#x20AC; &amp;quot;"), "condomínio € &quot;")
    }
}
