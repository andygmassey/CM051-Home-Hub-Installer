# Tool Routing Guide

CALENDAR: Use http_request with url="http://localhost:8089/calendar?days=7" (or days=1 for today)
EMAIL: Use http_request with url="http://localhost:8089/email?q=is:unread"
EMAIL WITH SUBJECT LINES: http://localhost:8089/email?q=is:unread&max=5
PEOPLE SEARCH: Use http_request with url="http://localhost:8089/people/search?q=fintech" — finds people by topic, industry, role, or any context. Returns name, org, relationship, and facts.
PERSON CONTEXT: Use http_request with url="http://localhost:8089/people/context?name=Jane" — returns everything known about a person: identifiers, facts, meeting history, last contact date. Use partial names.
SEARCH: Use web_search_tool
WEB PAGE: Use web_fetch
MATHS: Use calculator
BROWSING: Use http_request with url="http://localhost:8089/api/v1/browsing/search?q=local+ai&days=7&limit=5" - pages the user read, each with a short summary, topic tags and key entities (summary_status says whether one exists). Fetch the full url with web_fetch only when the summary is not enough.
REMEMBER: Use memory_store and memory_recall

IMPORTANT: For calendar, email, and people queries, ALWAYS use http_request to localhost:8089. Do NOT use google_workspace.

EXAMPLES:
- "Who do I know at HSBC?" → http_request url="http://localhost:8089/people/search?q=HSBC+banking"
- "What do I know about Jane?" → http_request url="http://localhost:8089/people/context?name=Jane"
- "Who have I met recently in tech?" → http_request url="http://localhost:8089/people/search?q=technology+innovation"
