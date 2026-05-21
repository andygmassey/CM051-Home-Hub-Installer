# Tool Routing Guide

CALENDAR: Use http_request with url="http://localhost:8089/calendar?days=7" (or days=1 for today)
EMAIL: Use http_request with url="http://localhost:8089/email?q=is:unread"
EMAIL WITH SUBJECT LINES: http://localhost:8089/email?q=is:unread&max=5
PEOPLE SEARCH: Use http_request with url="http://localhost:8089/people/search?q=fintech" — finds people by topic, industry, role, or any context. Returns name, org, relationship, and facts.
PERSON CONTEXT: Use http_request with url="http://localhost:8089/people/context?name=Danny" — returns everything known about a person: identifiers, facts, meeting history, last contact date. Use partial names.
SEARCH: Use web_search_tool
WEB PAGE: Use web_fetch
MATHS: Use calculator
REMEMBER: Use memory_store and memory_recall

IMPORTANT: For calendar, email, and people queries, ALWAYS use http_request to localhost:8089. Do NOT use google_workspace.

EXAMPLES:
- "Who do I know at HSBC?" → http_request url="http://localhost:8089/people/search?q=HSBC+banking"
- "What do I know about Arnaud?" → http_request url="http://localhost:8089/people/context?name=Arnaud"
- "Who have I met recently in tech?" → http_request url="http://localhost:8089/people/search?q=technology+innovation"
