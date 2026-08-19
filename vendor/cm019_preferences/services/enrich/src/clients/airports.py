"""Static airport code lookup for travel pattern analysis."""

from dataclasses import dataclass
from typing import Dict, Optional


@dataclass
class AirportInfo:
    """Airport information including city, country, and region."""
    code: str
    city: str
    country: str
    region: str
    name: Optional[str] = None  # Full airport name


class AirportLookup:
    """
    Static dictionary lookup for airport codes.

    Maps IATA airport codes to city, country, and region for travel pattern analysis.
    No external API needed - this is a static dictionary.

    Regions:
    - Europe
    - North America
    - Asia-Pacific
    - Middle East
    - Africa
    - South America
    - Oceania

    Usage:
        lookup = AirportLookup()
        info = lookup.lookup("HKG")
        print(info.city)     # "Hong Kong"
        print(info.region)   # "Asia-Pacific"
    """

    # Static dictionary of major international airports
    # Covers major hubs and likely airports from Calendar travel data
    AIRPORTS: Dict[str, AirportInfo] = {
        # Asia-Pacific
        "HKG": AirportInfo("HKG", "Hong Kong", "China", "Asia-Pacific", "Hong Kong International Airport"),
        "PEK": AirportInfo("PEK", "Beijing", "China", "Asia-Pacific", "Beijing Capital International Airport"),
        "PVG": AirportInfo("PVG", "Shanghai", "China", "Asia-Pacific", "Shanghai Pudong International Airport"),
        "SHA": AirportInfo("SHA", "Shanghai", "China", "Asia-Pacific", "Shanghai Hongqiao International Airport"),
        "CAN": AirportInfo("CAN", "Guangzhou", "China", "Asia-Pacific", "Guangzhou Baiyun International Airport"),
        "SZX": AirportInfo("SZX", "Shenzhen", "China", "Asia-Pacific", "Shenzhen Bao'an International Airport"),
        "TPE": AirportInfo("TPE", "Taipei", "Taiwan", "Asia-Pacific", "Taiwan Taoyuan International Airport"),
        "TSA": AirportInfo("TSA", "Taipei", "Taiwan", "Asia-Pacific", "Taipei Songshan Airport"),
        "NRT": AirportInfo("NRT", "Tokyo", "Japan", "Asia-Pacific", "Narita International Airport"),
        "HND": AirportInfo("HND", "Tokyo", "Japan", "Asia-Pacific", "Tokyo Haneda Airport"),
        "KIX": AirportInfo("KIX", "Osaka", "Japan", "Asia-Pacific", "Kansai International Airport"),
        "ITM": AirportInfo("ITM", "Osaka", "Japan", "Asia-Pacific", "Osaka Itami Airport"),
        "FUK": AirportInfo("FUK", "Fukuoka", "Japan", "Asia-Pacific", "Fukuoka Airport"),
        "NGO": AirportInfo("NGO", "Nagoya", "Japan", "Asia-Pacific", "Chubu Centrair International Airport"),
        "ICN": AirportInfo("ICN", "Seoul", "South Korea", "Asia-Pacific", "Incheon International Airport"),
        "GMP": AirportInfo("GMP", "Seoul", "South Korea", "Asia-Pacific", "Gimpo International Airport"),
        "SIN": AirportInfo("SIN", "Singapore", "Singapore", "Asia-Pacific", "Singapore Changi Airport"),
        "KUL": AirportInfo("KUL", "Kuala Lumpur", "Malaysia", "Asia-Pacific", "Kuala Lumpur International Airport"),
        "BKK": AirportInfo("BKK", "Bangkok", "Thailand", "Asia-Pacific", "Suvarnabhumi Airport"),
        "DMK": AirportInfo("DMK", "Bangkok", "Thailand", "Asia-Pacific", "Don Mueang International Airport"),
        "HAN": AirportInfo("HAN", "Hanoi", "Vietnam", "Asia-Pacific", "Noi Bai International Airport"),
        "SGN": AirportInfo("SGN", "Ho Chi Minh City", "Vietnam", "Asia-Pacific", "Tan Son Nhat International Airport"),
        "CGK": AirportInfo("CGK", "Jakarta", "Indonesia", "Asia-Pacific", "Soekarno-Hatta International Airport"),
        "DPS": AirportInfo("DPS", "Bali", "Indonesia", "Asia-Pacific", "Ngurah Rai International Airport"),
        "MNL": AirportInfo("MNL", "Manila", "Philippines", "Asia-Pacific", "Ninoy Aquino International Airport"),
        "DEL": AirportInfo("DEL", "New Delhi", "India", "Asia-Pacific", "Indira Gandhi International Airport"),
        "BOM": AirportInfo("BOM", "Mumbai", "India", "Asia-Pacific", "Chhatrapati Shivaji Maharaj International Airport"),
        "BLR": AirportInfo("BLR", "Bangalore", "India", "Asia-Pacific", "Kempegowda International Airport"),
        "MAA": AirportInfo("MAA", "Chennai", "India", "Asia-Pacific", "Chennai International Airport"),
        "HYD": AirportInfo("HYD", "Hyderabad", "India", "Asia-Pacific", "Rajiv Gandhi International Airport"),
        "CCU": AirportInfo("CCU", "Kolkata", "India", "Asia-Pacific", "Netaji Subhas Chandra Bose International Airport"),
        "CMB": AirportInfo("CMB", "Colombo", "Sri Lanka", "Asia-Pacific", "Bandaranaike International Airport"),
        "DAC": AirportInfo("DAC", "Dhaka", "Bangladesh", "Asia-Pacific", "Hazrat Shahjalal International Airport"),
        "KTM": AirportInfo("KTM", "Kathmandu", "Nepal", "Asia-Pacific", "Tribhuvan International Airport"),
        "RGN": AirportInfo("RGN", "Yangon", "Myanmar", "Asia-Pacific", "Yangon International Airport"),
        "PNH": AirportInfo("PNH", "Phnom Penh", "Cambodia", "Asia-Pacific", "Phnom Penh International Airport"),
        "REP": AirportInfo("REP", "Siem Reap", "Cambodia", "Asia-Pacific", "Siem Reap International Airport"),
        "MLE": AirportInfo("MLE", "Male", "Maldives", "Asia-Pacific", "Velana International Airport"),

        # Oceania
        "SYD": AirportInfo("SYD", "Sydney", "Australia", "Oceania", "Sydney Kingsford Smith Airport"),
        "MEL": AirportInfo("MEL", "Melbourne", "Australia", "Oceania", "Melbourne Airport"),
        "BNE": AirportInfo("BNE", "Brisbane", "Australia", "Oceania", "Brisbane Airport"),
        "PER": AirportInfo("PER", "Perth", "Australia", "Oceania", "Perth Airport"),
        "ADL": AirportInfo("ADL", "Adelaide", "Australia", "Oceania", "Adelaide Airport"),
        "CBR": AirportInfo("CBR", "Canberra", "Australia", "Oceania", "Canberra Airport"),
        "AKL": AirportInfo("AKL", "Auckland", "New Zealand", "Oceania", "Auckland Airport"),
        "WLG": AirportInfo("WLG", "Wellington", "New Zealand", "Oceania", "Wellington Airport"),
        "CHC": AirportInfo("CHC", "Christchurch", "New Zealand", "Oceania", "Christchurch Airport"),
        "ZQN": AirportInfo("ZQN", "Queenstown", "New Zealand", "Oceania", "Queenstown Airport"),
        "NAN": AirportInfo("NAN", "Nadi", "Fiji", "Oceania", "Nadi International Airport"),
        "PPT": AirportInfo("PPT", "Papeete", "French Polynesia", "Oceania", "Faa'a International Airport"),

        # Europe
        "LHR": AirportInfo("LHR", "London", "United Kingdom", "Europe", "London Heathrow Airport"),
        "LGW": AirportInfo("LGW", "London", "United Kingdom", "Europe", "London Gatwick Airport"),
        "STN": AirportInfo("STN", "London", "United Kingdom", "Europe", "London Stansted Airport"),
        "LTN": AirportInfo("LTN", "London", "United Kingdom", "Europe", "London Luton Airport"),
        "LCY": AirportInfo("LCY", "London", "United Kingdom", "Europe", "London City Airport"),
        "MAN": AirportInfo("MAN", "Manchester", "United Kingdom", "Europe", "Manchester Airport"),
        "EDI": AirportInfo("EDI", "Edinburgh", "United Kingdom", "Europe", "Edinburgh Airport"),
        "BHX": AirportInfo("BHX", "Birmingham", "United Kingdom", "Europe", "Birmingham Airport"),
        "GLA": AirportInfo("GLA", "Glasgow", "United Kingdom", "Europe", "Glasgow Airport"),
        "CDG": AirportInfo("CDG", "Paris", "France", "Europe", "Paris Charles de Gaulle Airport"),
        "ORY": AirportInfo("ORY", "Paris", "France", "Europe", "Paris Orly Airport"),
        "NCE": AirportInfo("NCE", "Nice", "France", "Europe", "Nice Cote d'Azur Airport"),
        "LYS": AirportInfo("LYS", "Lyon", "France", "Europe", "Lyon-Saint Exupery Airport"),
        "MRS": AirportInfo("MRS", "Marseille", "France", "Europe", "Marseille Provence Airport"),
        "FRA": AirportInfo("FRA", "Frankfurt", "Germany", "Europe", "Frankfurt Airport"),
        "MUC": AirportInfo("MUC", "Munich", "Germany", "Europe", "Munich Airport"),
        "TXL": AirportInfo("TXL", "Berlin", "Germany", "Europe", "Berlin Tegel Airport"),
        "BER": AirportInfo("BER", "Berlin", "Germany", "Europe", "Berlin Brandenburg Airport"),
        "HAM": AirportInfo("HAM", "Hamburg", "Germany", "Europe", "Hamburg Airport"),
        "DUS": AirportInfo("DUS", "Dusseldorf", "Germany", "Europe", "Dusseldorf Airport"),
        "CGN": AirportInfo("CGN", "Cologne", "Germany", "Europe", "Cologne Bonn Airport"),
        "STR": AirportInfo("STR", "Stuttgart", "Germany", "Europe", "Stuttgart Airport"),
        "AMS": AirportInfo("AMS", "Amsterdam", "Netherlands", "Europe", "Amsterdam Schiphol Airport"),
        "BRU": AirportInfo("BRU", "Brussels", "Belgium", "Europe", "Brussels Airport"),
        "ZRH": AirportInfo("ZRH", "Zurich", "Switzerland", "Europe", "Zurich Airport"),
        "GVA": AirportInfo("GVA", "Geneva", "Switzerland", "Europe", "Geneva Airport"),
        "BSL": AirportInfo("BSL", "Basel", "Switzerland", "Europe", "EuroAirport Basel-Mulhouse-Freiburg"),
        "VIE": AirportInfo("VIE", "Vienna", "Austria", "Europe", "Vienna International Airport"),
        "CPH": AirportInfo("CPH", "Copenhagen", "Denmark", "Europe", "Copenhagen Airport"),
        "ARN": AirportInfo("ARN", "Stockholm", "Sweden", "Europe", "Stockholm Arlanda Airport"),
        "OSL": AirportInfo("OSL", "Oslo", "Norway", "Europe", "Oslo Gardermoen Airport"),
        "HEL": AirportInfo("HEL", "Helsinki", "Finland", "Europe", "Helsinki-Vantaa Airport"),
        "FCO": AirportInfo("FCO", "Rome", "Italy", "Europe", "Rome Fiumicino Airport"),
        "MXP": AirportInfo("MXP", "Milan", "Italy", "Europe", "Milan Malpensa Airport"),
        "LIN": AirportInfo("LIN", "Milan", "Italy", "Europe", "Milan Linate Airport"),
        "VCE": AirportInfo("VCE", "Venice", "Italy", "Europe", "Venice Marco Polo Airport"),
        "NAP": AirportInfo("NAP", "Naples", "Italy", "Europe", "Naples International Airport"),
        "FLR": AirportInfo("FLR", "Florence", "Italy", "Europe", "Florence Airport"),
        "MAD": AirportInfo("MAD", "Madrid", "Spain", "Europe", "Adolfo Suarez Madrid-Barajas Airport"),
        "BCN": AirportInfo("BCN", "Barcelona", "Spain", "Europe", "Barcelona-El Prat Airport"),
        "PMI": AirportInfo("PMI", "Palma de Mallorca", "Spain", "Europe", "Palma de Mallorca Airport"),
        "AGP": AirportInfo("AGP", "Malaga", "Spain", "Europe", "Malaga-Costa del Sol Airport"),
        "IBZ": AirportInfo("IBZ", "Ibiza", "Spain", "Europe", "Ibiza Airport"),
        "LIS": AirportInfo("LIS", "Lisbon", "Portugal", "Europe", "Lisbon Portela Airport"),
        "OPO": AirportInfo("OPO", "Porto", "Portugal", "Europe", "Francisco Sa Carneiro Airport"),
        "ATH": AirportInfo("ATH", "Athens", "Greece", "Europe", "Athens International Airport"),
        "SKG": AirportInfo("SKG", "Thessaloniki", "Greece", "Europe", "Thessaloniki Airport"),
        "JMK": AirportInfo("JMK", "Mykonos", "Greece", "Europe", "Mykonos Airport"),
        "JTR": AirportInfo("JTR", "Santorini", "Greece", "Europe", "Santorini Airport"),
        "IST": AirportInfo("IST", "Istanbul", "Turkey", "Europe", "Istanbul Airport"),
        "SAW": AirportInfo("SAW", "Istanbul", "Turkey", "Europe", "Sabiha Gokcen International Airport"),
        "DUB": AirportInfo("DUB", "Dublin", "Ireland", "Europe", "Dublin Airport"),
        "WAW": AirportInfo("WAW", "Warsaw", "Poland", "Europe", "Warsaw Chopin Airport"),
        "KRK": AirportInfo("KRK", "Krakow", "Poland", "Europe", "John Paul II International Airport Krakow-Balice"),
        "PRG": AirportInfo("PRG", "Prague", "Czech Republic", "Europe", "Vaclav Havel Airport Prague"),
        "BUD": AirportInfo("BUD", "Budapest", "Hungary", "Europe", "Budapest Ferenc Liszt International Airport"),
        "OTP": AirportInfo("OTP", "Bucharest", "Romania", "Europe", "Henri Coanda International Airport"),
        "SOF": AirportInfo("SOF", "Sofia", "Bulgaria", "Europe", "Sofia Airport"),
        "BEG": AirportInfo("BEG", "Belgrade", "Serbia", "Europe", "Belgrade Nikola Tesla Airport"),
        "ZAG": AirportInfo("ZAG", "Zagreb", "Croatia", "Europe", "Franjo Tudman Airport"),
        "LJU": AirportInfo("LJU", "Ljubljana", "Slovenia", "Europe", "Ljubljana Joze Pucnik Airport"),
        "TLL": AirportInfo("TLL", "Tallinn", "Estonia", "Europe", "Lennart Meri Tallinn Airport"),
        "RIX": AirportInfo("RIX", "Riga", "Latvia", "Europe", "Riga International Airport"),
        "VNO": AirportInfo("VNO", "Vilnius", "Lithuania", "Europe", "Vilnius Airport"),
        "KEF": AirportInfo("KEF", "Reykjavik", "Iceland", "Europe", "Keflavik International Airport"),
        "LUX": AirportInfo("LUX", "Luxembourg", "Luxembourg", "Europe", "Luxembourg Airport"),
        "MLA": AirportInfo("MLA", "Valletta", "Malta", "Europe", "Malta International Airport"),
        "TIA": AirportInfo("TIA", "Tirana", "Albania", "Europe", "Tirana International Airport"),
        "SKP": AirportInfo("SKP", "Skopje", "North Macedonia", "Europe", "Skopje International Airport"),
        "SJJ": AirportInfo("SJJ", "Sarajevo", "Bosnia and Herzegovina", "Europe", "Sarajevo International Airport"),
        "TGD": AirportInfo("TGD", "Podgorica", "Montenegro", "Europe", "Podgorica Airport"),
        "KSC": AirportInfo("KSC", "Kosice", "Slovakia", "Europe", "Kosice International Airport"),

        # North America
        "JFK": AirportInfo("JFK", "New York", "United States", "North America", "John F. Kennedy International Airport"),
        "EWR": AirportInfo("EWR", "Newark", "United States", "North America", "Newark Liberty International Airport"),
        "LGA": AirportInfo("LGA", "New York", "United States", "North America", "LaGuardia Airport"),
        "LAX": AirportInfo("LAX", "Los Angeles", "United States", "North America", "Los Angeles International Airport"),
        "SFO": AirportInfo("SFO", "San Francisco", "United States", "North America", "San Francisco International Airport"),
        "SJC": AirportInfo("SJC", "San Jose", "United States", "North America", "San Jose International Airport"),
        "OAK": AirportInfo("OAK", "Oakland", "United States", "North America", "Oakland International Airport"),
        "ORD": AirportInfo("ORD", "Chicago", "United States", "North America", "Chicago O'Hare International Airport"),
        "MDW": AirportInfo("MDW", "Chicago", "United States", "North America", "Chicago Midway International Airport"),
        "ATL": AirportInfo("ATL", "Atlanta", "United States", "North America", "Hartsfield-Jackson Atlanta International Airport"),
        "DFW": AirportInfo("DFW", "Dallas", "United States", "North America", "Dallas/Fort Worth International Airport"),
        "DEN": AirportInfo("DEN", "Denver", "United States", "North America", "Denver International Airport"),
        "SEA": AirportInfo("SEA", "Seattle", "United States", "North America", "Seattle-Tacoma International Airport"),
        "BOS": AirportInfo("BOS", "Boston", "United States", "North America", "Boston Logan International Airport"),
        "MIA": AirportInfo("MIA", "Miami", "United States", "North America", "Miami International Airport"),
        "FLL": AirportInfo("FLL", "Fort Lauderdale", "United States", "North America", "Fort Lauderdale-Hollywood International Airport"),
        "MCO": AirportInfo("MCO", "Orlando", "United States", "North America", "Orlando International Airport"),
        "TPA": AirportInfo("TPA", "Tampa", "United States", "North America", "Tampa International Airport"),
        "PHX": AirportInfo("PHX", "Phoenix", "United States", "North America", "Phoenix Sky Harbor International Airport"),
        "IAD": AirportInfo("IAD", "Washington D.C.", "United States", "North America", "Washington Dulles International Airport"),
        "DCA": AirportInfo("DCA", "Washington D.C.", "United States", "North America", "Ronald Reagan Washington National Airport"),
        "BWI": AirportInfo("BWI", "Baltimore", "United States", "North America", "Baltimore/Washington International Airport"),
        "PHL": AirportInfo("PHL", "Philadelphia", "United States", "North America", "Philadelphia International Airport"),
        "MSP": AirportInfo("MSP", "Minneapolis", "United States", "North America", "Minneapolis-Saint Paul International Airport"),
        "DTW": AirportInfo("DTW", "Detroit", "United States", "North America", "Detroit Metropolitan Wayne County Airport"),
        "CLT": AirportInfo("CLT", "Charlotte", "United States", "North America", "Charlotte Douglas International Airport"),
        "SLC": AirportInfo("SLC", "Salt Lake City", "United States", "North America", "Salt Lake City International Airport"),
        "PDX": AirportInfo("PDX", "Portland", "United States", "North America", "Portland International Airport"),
        "LAS": AirportInfo("LAS", "Las Vegas", "United States", "North America", "Harry Reid International Airport"),
        "SAN": AirportInfo("SAN", "San Diego", "United States", "North America", "San Diego International Airport"),
        "AUS": AirportInfo("AUS", "Austin", "United States", "North America", "Austin-Bergstrom International Airport"),
        "IAH": AirportInfo("IAH", "Houston", "United States", "North America", "George Bush Intercontinental Airport"),
        "HOU": AirportInfo("HOU", "Houston", "United States", "North America", "William P. Hobby Airport"),
        "HNL": AirportInfo("HNL", "Honolulu", "United States", "North America", "Daniel K. Inouye International Airport"),
        "OGG": AirportInfo("OGG", "Maui", "United States", "North America", "Kahului Airport"),
        "ANC": AirportInfo("ANC", "Anchorage", "United States", "North America", "Ted Stevens Anchorage International Airport"),
        "YYZ": AirportInfo("YYZ", "Toronto", "Canada", "North America", "Toronto Pearson International Airport"),
        "YUL": AirportInfo("YUL", "Montreal", "Canada", "North America", "Montreal-Trudeau International Airport"),
        "YVR": AirportInfo("YVR", "Vancouver", "Canada", "North America", "Vancouver International Airport"),
        "YYC": AirportInfo("YYC", "Calgary", "Canada", "North America", "Calgary International Airport"),
        "YEG": AirportInfo("YEG", "Edmonton", "Canada", "North America", "Edmonton International Airport"),
        "YOW": AirportInfo("YOW", "Ottawa", "Canada", "North America", "Ottawa Macdonald-Cartier International Airport"),
        "YWG": AirportInfo("YWG", "Winnipeg", "Canada", "North America", "Winnipeg James Armstrong Richardson International Airport"),
        "YHZ": AirportInfo("YHZ", "Halifax", "Canada", "North America", "Halifax Stanfield International Airport"),
        "MEX": AirportInfo("MEX", "Mexico City", "Mexico", "North America", "Mexico City International Airport"),
        "CUN": AirportInfo("CUN", "Cancun", "Mexico", "North America", "Cancun International Airport"),
        "GDL": AirportInfo("GDL", "Guadalajara", "Mexico", "North America", "Guadalajara International Airport"),
        "SJD": AirportInfo("SJD", "Los Cabos", "Mexico", "North America", "Los Cabos International Airport"),
        "PVR": AirportInfo("PVR", "Puerto Vallarta", "Mexico", "North America", "Licenciado Gustavo Diaz Ordaz International Airport"),

        # South America
        "GRU": AirportInfo("GRU", "Sao Paulo", "Brazil", "South America", "Sao Paulo-Guarulhos International Airport"),
        "GIG": AirportInfo("GIG", "Rio de Janeiro", "Brazil", "South America", "Rio de Janeiro-Galeao International Airport"),
        "BSB": AirportInfo("BSB", "Brasilia", "Brazil", "South America", "Brasilia International Airport"),
        "EZE": AirportInfo("EZE", "Buenos Aires", "Argentina", "South America", "Ministro Pistarini International Airport"),
        "AEP": AirportInfo("AEP", "Buenos Aires", "Argentina", "South America", "Aeroparque Jorge Newbery"),
        "SCL": AirportInfo("SCL", "Santiago", "Chile", "South America", "Arturo Merino Benitez International Airport"),
        "LIM": AirportInfo("LIM", "Lima", "Peru", "South America", "Jorge Chavez International Airport"),
        "BOG": AirportInfo("BOG", "Bogota", "Colombia", "South America", "El Dorado International Airport"),
        "MDE": AirportInfo("MDE", "Medellin", "Colombia", "South America", "Jose Maria Cordova International Airport"),
        "CTG": AirportInfo("CTG", "Cartagena", "Colombia", "South America", "Rafael Nunez International Airport"),
        "UIO": AirportInfo("UIO", "Quito", "Ecuador", "South America", "Mariscal Sucre International Airport"),
        "GYE": AirportInfo("GYE", "Guayaquil", "Ecuador", "South America", "Jose Joaquin de Olmedo International Airport"),
        "CCS": AirportInfo("CCS", "Caracas", "Venezuela", "South America", "Simon Bolivar International Airport"),
        "MVD": AirportInfo("MVD", "Montevideo", "Uruguay", "South America", "Carrasco International Airport"),
        "ASU": AirportInfo("ASU", "Asuncion", "Paraguay", "South America", "Silvio Pettirossi International Airport"),
        "VVI": AirportInfo("VVI", "Santa Cruz", "Bolivia", "South America", "Viru Viru International Airport"),
        "LPB": AirportInfo("LPB", "La Paz", "Bolivia", "South America", "El Alto International Airport"),

        # Middle East
        "DXB": AirportInfo("DXB", "Dubai", "United Arab Emirates", "Middle East", "Dubai International Airport"),
        "AUH": AirportInfo("AUH", "Abu Dhabi", "United Arab Emirates", "Middle East", "Abu Dhabi International Airport"),
        "DOH": AirportInfo("DOH", "Doha", "Qatar", "Middle East", "Hamad International Airport"),
        "JED": AirportInfo("JED", "Jeddah", "Saudi Arabia", "Middle East", "King Abdulaziz International Airport"),
        "RUH": AirportInfo("RUH", "Riyadh", "Saudi Arabia", "Middle East", "King Khalid International Airport"),
        "KWI": AirportInfo("KWI", "Kuwait City", "Kuwait", "Middle East", "Kuwait International Airport"),
        "BAH": AirportInfo("BAH", "Manama", "Bahrain", "Middle East", "Bahrain International Airport"),
        "MCT": AirportInfo("MCT", "Muscat", "Oman", "Middle East", "Muscat International Airport"),
        "AMM": AirportInfo("AMM", "Amman", "Jordan", "Middle East", "Queen Alia International Airport"),
        "BEY": AirportInfo("BEY", "Beirut", "Lebanon", "Middle East", "Beirut-Rafic Hariri International Airport"),
        "TLV": AirportInfo("TLV", "Tel Aviv", "Israel", "Middle East", "Ben Gurion Airport"),
        "CAI": AirportInfo("CAI", "Cairo", "Egypt", "Middle East", "Cairo International Airport"),
        "SSH": AirportInfo("SSH", "Sharm El Sheikh", "Egypt", "Middle East", "Sharm El Sheikh International Airport"),
        "HRG": AirportInfo("HRG", "Hurghada", "Egypt", "Middle East", "Hurghada International Airport"),
        "IKA": AirportInfo("IKA", "Tehran", "Iran", "Middle East", "Imam Khomeini International Airport"),
        "BGW": AirportInfo("BGW", "Baghdad", "Iraq", "Middle East", "Baghdad International Airport"),

        # Africa
        "JNB": AirportInfo("JNB", "Johannesburg", "South Africa", "Africa", "O.R. Tambo International Airport"),
        "CPT": AirportInfo("CPT", "Cape Town", "South Africa", "Africa", "Cape Town International Airport"),
        "DUR": AirportInfo("DUR", "Durban", "South Africa", "Africa", "King Shaka International Airport"),
        "NBO": AirportInfo("NBO", "Nairobi", "Kenya", "Africa", "Jomo Kenyatta International Airport"),
        "MBA": AirportInfo("MBA", "Mombasa", "Kenya", "Africa", "Moi International Airport"),
        "ADD": AirportInfo("ADD", "Addis Ababa", "Ethiopia", "Africa", "Bole International Airport"),
        "LOS": AirportInfo("LOS", "Lagos", "Nigeria", "Africa", "Murtala Muhammed International Airport"),
        "ABV": AirportInfo("ABV", "Abuja", "Nigeria", "Africa", "Nnamdi Azikiwe International Airport"),
        "CMN": AirportInfo("CMN", "Casablanca", "Morocco", "Africa", "Mohammed V International Airport"),
        "RAK": AirportInfo("RAK", "Marrakech", "Morocco", "Africa", "Marrakech Menara Airport"),
        "TUN": AirportInfo("TUN", "Tunis", "Tunisia", "Africa", "Tunis-Carthage International Airport"),
        "ALG": AirportInfo("ALG", "Algiers", "Algeria", "Africa", "Houari Boumediene Airport"),
        "ACC": AirportInfo("ACC", "Accra", "Ghana", "Africa", "Kotoka International Airport"),
        "DSS": AirportInfo("DSS", "Dakar", "Senegal", "Africa", "Blaise Diagne International Airport"),
        "TNR": AirportInfo("TNR", "Antananarivo", "Madagascar", "Africa", "Ivato International Airport"),
        "MRU": AirportInfo("MRU", "Mauritius", "Mauritius", "Africa", "Sir Seewoosagur Ramgoolam International Airport"),
        "SEZ": AirportInfo("SEZ", "Mahe", "Seychelles", "Africa", "Seychelles International Airport"),
        "DAR": AirportInfo("DAR", "Dar es Salaam", "Tanzania", "Africa", "Julius Nyerere International Airport"),
        "ZNZ": AirportInfo("ZNZ", "Zanzibar", "Tanzania", "Africa", "Abeid Amani Karume International Airport"),
        "EBB": AirportInfo("EBB", "Entebbe", "Uganda", "Africa", "Entebbe International Airport"),
        "KGL": AirportInfo("KGL", "Kigali", "Rwanda", "Africa", "Kigali International Airport"),
        "MPM": AirportInfo("MPM", "Maputo", "Mozambique", "Africa", "Maputo International Airport"),
        "VFA": AirportInfo("VFA", "Victoria Falls", "Zimbabwe", "Africa", "Victoria Falls Airport"),
        "HRE": AirportInfo("HRE", "Harare", "Zimbabwe", "Africa", "Robert Gabriel Mugabe International Airport"),
        "WDH": AirportInfo("WDH", "Windhoek", "Namibia", "Africa", "Hosea Kutako International Airport"),
        "LUN": AirportInfo("LUN", "Lusaka", "Zambia", "Africa", "Kenneth Kaunda International Airport"),
        "GBE": AirportInfo("GBE", "Gaborone", "Botswana", "Africa", "Sir Seretse Khama International Airport"),

        # Caribbean
        "NAS": AirportInfo("NAS", "Nassau", "Bahamas", "North America", "Lynden Pindling International Airport"),
        "MBJ": AirportInfo("MBJ", "Montego Bay", "Jamaica", "North America", "Sangster International Airport"),
        "KIN": AirportInfo("KIN", "Kingston", "Jamaica", "North America", "Norman Manley International Airport"),
        "SJU": AirportInfo("SJU", "San Juan", "Puerto Rico", "North America", "Luis Munoz Marin International Airport"),
        "PUJ": AirportInfo("PUJ", "Punta Cana", "Dominican Republic", "North America", "Punta Cana International Airport"),
        "SDQ": AirportInfo("SDQ", "Santo Domingo", "Dominican Republic", "North America", "Las Americas International Airport"),
        "HAV": AirportInfo("HAV", "Havana", "Cuba", "North America", "Jose Marti International Airport"),
        "AUA": AirportInfo("AUA", "Aruba", "Aruba", "North America", "Queen Beatrix International Airport"),
        "CUR": AirportInfo("CUR", "Curacao", "Curacao", "North America", "Curacao International Airport"),
        "SXM": AirportInfo("SXM", "Sint Maarten", "Sint Maarten", "North America", "Princess Juliana International Airport"),
        "BGI": AirportInfo("BGI", "Bridgetown", "Barbados", "North America", "Grantley Adams International Airport"),
        "POS": AirportInfo("POS", "Port of Spain", "Trinidad and Tobago", "North America", "Piarco International Airport"),
    }

    def __init__(self):
        """Initialize the airport lookup."""
        pass

    def lookup(self, code: str) -> Optional[AirportInfo]:
        """
        Look up airport information by IATA code.

        Args:
            code: IATA airport code (e.g., "HKG", "LHR")

        Returns:
            AirportInfo with city, country, region, and name, or None if not found
        """
        # Normalize the code to uppercase
        normalized_code = code.strip().upper()
        return self.AIRPORTS.get(normalized_code)

    def lookup_batch(self, codes: list[str]) -> Dict[str, Optional[AirportInfo]]:
        """
        Look up multiple airport codes at once.

        Args:
            codes: List of IATA airport codes

        Returns:
            Dictionary mapping codes to AirportInfo (or None if not found)
        """
        return {code: self.lookup(code) for code in codes}

    def get_all_codes(self) -> list[str]:
        """Get list of all supported airport codes."""
        return list(self.AIRPORTS.keys())

    def get_airports_by_region(self, region: str) -> list[AirportInfo]:
        """
        Get all airports in a specific region.

        Args:
            region: Region name (Europe, North America, Asia-Pacific, etc.)

        Returns:
            List of AirportInfo objects in that region
        """
        return [
            airport for airport in self.AIRPORTS.values()
            if airport.region.lower() == region.lower()
        ]

    def get_airports_by_country(self, country: str) -> list[AirportInfo]:
        """
        Get all airports in a specific country.

        Args:
            country: Country name

        Returns:
            List of AirportInfo objects in that country
        """
        return [
            airport for airport in self.AIRPORTS.values()
            if airport.country.lower() == country.lower()
        ]

    def stats(self) -> Dict[str, int]:
        """Get statistics about the airport database."""
        by_region: Dict[str, int] = {}
        by_country: Dict[str, int] = {}

        for airport in self.AIRPORTS.values():
            by_region[airport.region] = by_region.get(airport.region, 0) + 1
            by_country[airport.country] = by_country.get(airport.country, 0) + 1

        return {
            "total_airports": len(self.AIRPORTS),
            "regions": len(by_region),
            "countries": len(by_country),
            "by_region": by_region,
        }
