--------------------------------------------------------------------------------
-- HDI Lebensversicherung Extension for MoneyMoney https://moneymoney-app.com
-- Copyright 2025 Ansgar Scheffold
--------------------------------------------------------------------------------
WebBanking {
    version     = 1.00,
    url         = "https://www.hdi.de/mein-hdi/login",
    services    = {"HDI Lebensversicherung"},
    description = "HDI Depotbestände für Versicherungspolicen in MoneyMoney anzeigen"
}

--------------------------------------------------------------------------------
-- Constants and global variables
--------------------------------------------------------------------------------
local connection = nil
local sessionCookies = nil
local oktaSessionToken = nil

-- Debug settings
local DEBUG_MODE = true

-- API-URLs
local OKTA_LOGIN_URL = "https://okp.login.hdi.de/api/v1/authn"
local OKTA_SESSION_URL = "https://okp.login.hdi.de/api/v1/sessions/me"
local HDI_BASE_URL = "https://www.hdi.de"
local CONTRACTS_URL = HDI_BASE_URL .. "/mein-hdi/vertraege"
local CONTRACT_DETAILS_BASE_URL = HDI_BASE_URL .. "/mein-hdi/vertragsdetails/leben/"
local OKTA_APP_EMBED_URL = "https://okp.login.hdi.de/home/hdi-okp_okpprod_1/0oa533a8c64XNE6BW417/aln533dpthvDpFsjN417"
local JUSTETF_API = "https://www.justetf.com/api/etfs/cards?locale=en&currency=EUR&isin="

-- Configuration: If true, current prices and position amounts are calculated
-- from API (justETF): amount = price * quantity; otherwise values from
-- web scraping (HDI site) are used.
local USE_API = false

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------
-- Helper function for logging
local function log(message)
  if DEBUG_MODE then
    print(extensionName .. ": " .. message)
  end
end

-- Insert at the top of the script
local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Calculates amounts and total value based on API prices in positions.
local function recompute_totals_using_api(positions)
  local total = 0
  for i = 1, #positions do
    local p = positions[i]
    if p.price and p.quantity and p.quantity > 0 then
      local amt = p.price * p.quantity
      -- Round to cents
      amt = math.floor(amt * 100 + 0.5) / 100
      p.amount = amt
      total = total + amt
    else
      -- Fallback: if no API price available, keep existing amount (site value)
      if p.amount then total = total + p.amount end
    end
  end
  return math.floor(total * 100 + 0.5) / 100
end

--------------------------------------------------------------------------------
-- Core banking functions
--------------------------------------------------------------------------------
function SupportsBank(protocol, bankCode)
  log("SupportsBank called with protocol=" .. protocol .. ", bankCode=" .. bankCode)
  return protocol == ProtocolWebBanking and bankCode == "HDI Lebensversicherung"
end

function InitializeSession(protocol, bankCode, username, reserved, password)
  log("InitializeSession called for HDI Lebensversicherung")
  
  -- Create new connection
  connection = Connection()
  connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:139.0) Gecko/20100101 Firefox/139.0"
  connection.language = "de-DE"
  
  -- End existing Okta session (ignore errors)
  pcall(function()
    connection:request("DELETE", OKTA_SESSION_URL, nil, "application/json", {["Accept"] = "application/json"})
  end)
  
  -- Login headers
  local headers = {
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
    ["Origin"] = HDI_BASE_URL,
    ["Referer"] = HDI_BASE_URL .. "/mein-hdi/login",
    ["DNT"] = "1"
  }
  
  -- Login data as JSON
  local loginData = {
    username = username,
    password = password,
    options = {
      warnBeforePasswordExpired = true,
      multiOptionalFactorEnroll = false
    }
  }
  
  -- Send login request
  local loginJsonPayload = JSON():set(loginData):json()
  local content, charset, mimeType, filename, responseHeaders = connection:request(
    "POST", OKTA_LOGIN_URL, loginJsonPayload, "application/json", headers
  )
  
  -- Check if response was received
  if not content then
    log("No response received from server")
    return "No response received from server."
  end
  
  -- Analyze server response
  log("Login response received:")
  log(content)
  
  -- Parse JSON response
  local jsonResponse = JSON(content):dictionary()
  if not (jsonResponse and jsonResponse.sessionToken and jsonResponse.status == "SUCCESS") then
    log("Login failed: Unexpected response from server")
    return LoginFailed
  end

  oktaSessionToken = jsonResponse.sessionToken
  log("Login successful - Session token received")
    
  -- Set session cookie via redirect that starts SSO flow
  local sessionRedirectUrl = "https://okp.login.hdi.de/login/sessionCookieRedirect?token=" .. oktaSessionToken .. "&redirectUrl=" .. MM.urlencode(OKTA_APP_EMBED_URL)
  
  local redirectHeaders = {
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
  }
  
  -- This request will automatically follow redirects and return the SAML form page
  local samlFormHtml, charset, mimeType = connection:request("GET", sessionRedirectUrl, nil, nil, redirectHeaders)

  if not samlFormHtml or not string.find(samlFormHtml, "SAMLResponse") then
    log("Error retrieving SAML form.")
    log(samlFormHtml or "No content")
    return LoginFailed
  end
  
  log("SAML form received. Processing...")

  -- Process SAML form with MoneyMoney API submit() method
  local samlDoc = HTML(samlFormHtml)
  local form = samlDoc:xpath('//form[@id="appForm"]')
  
  if form:length() == 0 then
      log("SAML form could not be found in HTML.")
      return LoginFailed
  end
  
  local method, url, postContent, postContentType = form:submit()
  
  log("Sending SAML response to: " .. url)
  
  local finalPageContent = connection:request(method, url, postContent, postContentType)

  -- The response might contain a meta refresh tag. We need to extract the URL and go there.
  if finalPageContent and string.find(finalPageContent, 'meta http-equiv="refresh"') then
    local contentAttr = string.match(finalPageContent, 'content="([^"]+)"')
    if contentAttr then
      local refreshUrl = string.match(contentAttr, '[Uu][Rr][Ll]=(.*)')
      if refreshUrl then
        -- Trim whitespace
        refreshUrl = string.gsub(refreshUrl, "^%s*(.-)%s*$", "%1")
        log("SAML-POST successful, following refresh redirect to: " .. refreshUrl)
        -- The URL might be relative
        finalPageContent = connection:request("GET", refreshUrl)
      end
    end
  end

  local finalUrl = connection:getBaseURL()
  log("After SAML-POST and redirect landed on: " .. finalUrl)

  -- Check if login was successful (i.e. we are no longer on login page or error page)
  if not finalPageContent or string.find(finalPageContent, "Anmelden") or string.find(finalPageContent, "Fehler") then
    log("Error during HDI login after Okta authentication. Target page not reached.")
    log(finalPageContent or "No content")
    return LoginFailed
  end

  -- From here we should be logged in and have the cookies.
  sessionCookies = connection:getCookies()
  log("HDI session successfully established.")
  
  return nil
end

function ListAccounts(knownAccounts)
  log("ListAccounts called")

  if not connection or not sessionCookies then
    log("No active session")
    return {}
  end

  -- Headers for contract query
  local headers = {
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Cookie"] = sessionCookies,
    ["Referer"] = "https://www.hdi.de/mein-hdi/",
    ["Origin"] = "https://www.hdi.de"
  }

  -- Retrieve contract overview
  local content = connection:request("GET", CONTRACTS_URL, nil, nil, headers)

  if not content or string.find(content, "Anmelden") then
    log("Could not query account list or was logged out.")
    return {}
  end

  local accounts = {}

  -- Extract contracts from HTML
  for contractHtml in string.gmatch(content, '<li class="policy"[^>]*>(.-)</li>') do
    -- Only consider life insurance policies
    if string.find(contractHtml, "Lebens.-versicherung") then
      local contractLink = string.match(contractHtml, 'href="([^"]+)"')
      local contractId = nil
      if contractLink then
        contractId = string.match(contractLink, "vertragsdetails/leben/([^/]+)/")
      end

      local contractNumberRaw = string.match(contractHtml, 'Vers.-Nr.-:%s*</span>%s*<span>(.-)</span>')
      local productNameRaw = string.match(contractHtml, 'Produkt%s*:%s*</span>%s*<span>(.-)</span>')

      local contractNumber = contractNumberRaw and string.gsub(contractNumberRaw, "^%s*(.-)%s*$", "%1")
      local productName = productNameRaw and string.gsub(productNameRaw, "^%s*(.-)%s*$", "%1")

      if contractNumber and productName and contractId then
        local account = {
          name = productName,
          accountNumber = contractNumber,
          portfolio = true,
          type = AccountTypePortfolio,
          currency = "EUR",
          bankCode = "HDI Lebensversicherung",
          owner = "HDI Lebensversicherung",
          id = contractId,
          url = contractLink -- Store URL for later use
        }

        log("Found contract: " .. account.name .. " (No: " .. account.accountNumber .. ")")
        table.insert(accounts, account)
      end
    end
  end

  if #accounts == 0 then
    log("No contracts found on page.")
  end

  return accounts
end

--------------------------------------------------------------------------------
-- Web scraping helper functions
--------------------------------------------------------------------------------
-- Helper function to follow meta-refresh
local function followMetaRefresh(url)
  local content, charset, mimeType = connection:request("GET", url, nil, nil, {
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Cookie"] = sessionCookies,
    ["Referer"] = "https://www.hdi.de/mein-hdi/",
    ["Origin"] = "https://www.hdi.de"
  })
  
  if not content then return nil end
  
  -- Check for meta-refresh
  if string.find(content, 'meta http-equiv="refresh"') then
    local contentAttr = string.match(content, 'content="([^"]+)"')
    if contentAttr then
      local refreshUrl = string.match(contentAttr, '[Uu][Rr][Ll]=(.*)')
      if refreshUrl then
        refreshUrl = string.gsub(refreshUrl, "^%s*(.-)%s*$", "%1")
        log("Following meta-refresh to: " .. refreshUrl)
        return followMetaRefresh(refreshUrl)
      end
    end
  end
  
  return content
end

-- Helper function to normalize detail URLs
local function normalizeDetailHref(href)
  if not href or href == "" then return nil end
  if string.find(href, "^https?://") then return href end
  if string.find(href, "^/") then return "https://www.hdi.de" .. href end
  return "https://www.hdi.de/mein-hdi/" .. href
end

-- Helper function to parse German numbers
local function parse_de_number(text)
  if not text or text:match("^%s*$") then return 0 end
  local clean = text
    :gsub("%.", "")      -- Remove thousand separators
    :gsub(",", ".")      -- Comma→Point
    :gsub("[^%d%.]", "") -- only digits and point
  return tonumber(clean) or 0
end

-- Helper function to trim with Unicode support
local function trim_u(s)
  if not s then return "" end
  return s:gsub("^%s*(.-)%s*$", "%1")
end

--------------------------------------------------------------------------------
-- Account refresh functions
--------------------------------------------------------------------------------
function RefreshAccount(account, since)
  log("RefreshAccount called for: " .. account.name)
  
  -- 1) Determine detail URL
  local detailUrl = normalizeDetailHref(account.url)
  if not detailUrl then
    local listContent = followMetaRefresh(CONTRACTS_URL)
    if not listContent then error("Contract overview not loadable") end
    local html = HTML(listContent)

    -- NEW Layout: search directly via data-ta-vob
    local block = html:xpath("//*[@data-ta-vob='" .. account.accountNumber .. "']")
    if block:length() == 0 then
      block = html:xpath("//*[contains(@data-ta-vob,'" .. account.accountNumber .. "')]")
    end
    if block:length() > 0 then
      local href = block:get(1):xpath(".//a[contains(@href,'vertragsdetails/leben')][1]"):attr("href")
      if href and href ~= "" then
        detailUrl = normalizeDetailHref(href)
      end
    end

    -- Fallback: OLD Layout
    if not detailUrl then
      local old = html:xpath("//li[contains(@class,'policy')][@data-ta-vob='" .. account.accountNumber .. "']")
      if old:length() == 0 then
        old = html:xpath("//li[contains(@class,'policy')][contains(normalize-space(@data-ta-vob),'" .. account.accountNumber .. "')]")
      end
      if old:length() > 0 then
        local href = old:get(1):xpath(".//a[1]"):attr("href")
        if href and href ~= "" then
          detailUrl = normalizeDetailHref(href)
        end
      end
    end

    if not detailUrl then
      error("Contract block for number " .. account.accountNumber .. " not found (layout changed?)")
    end
  end

  -- 2) Load detail page (follow meta-refresh)
  local dContent = followMetaRefresh(detailUrl)
  if not dContent then error("Detail page not loadable") end
  local dHtml = HTML(dContent)

  -- 3) Parse fund positions - Based on actual HTML structure
  local positions = {}
  local container = dHtml:xpath("//div[contains(@class,'fondsdaten') and contains(@class,'d-lg-flex')][1]")
  
  if container:length() > 0 then
    -- Search for all fund rows (col-5 cell with name/ISIN)
    local nameCells = container:get(1):xpath(".//div[contains(@class,'col-5') and contains(@class,'zelle') and not(contains(@class,'kopf'))]")
    
    for i = 1, nameCells:length() do
      local nameCell = nameCells:get(i)
      
      -- Extract fund name and ISIN
      local name = ""
      local isin = ""
      
      -- Extract fund name from label
      local labels = nameCell:xpath(".//label")
      if labels:length() > 0 then
        name = trim_u(labels:get(1):text())
      end
      
      -- Extract ISIN from align-center div
      local isinDivs = nameCell:xpath(".//div[contains(@class,'align-center')]")
      if isinDivs:length() > 0 then
        isin = trim_u(isinDivs:get(1):text())
      end
      
      -- Only process if we have a valid name (not header)
      if name ~= "" and not name:lower():find("freie%s+fondsanlage") then
        -- Search for corresponding quote cell (col-1)
        local quoteCell = nameCell:xpath("following-sibling::div[contains(@class,'col-1') and contains(@class,'zelle')][1]")
        local quoteText = ""
        if quoteCell:length() > 0 then
          quoteText = trim_u(quoteCell:get(1):text())
        end
        
        -- Search for corresponding data cell (col-6 border-right-0)
        local dataCell = nameCell:xpath("following-sibling::div[contains(@class,'col-6') and contains(@class,'border-right-0')][1]")
        
        if dataCell:length() > 0 then
          local cols = dataCell:get(1):xpath(".//div[contains(@class,'row')]/div")
          
          if cols:length() >= 4 then
            -- Extract data from columns
            local qtyText   = trim_u(cols:get(1):text())
            local priceText = trim_u(cols:get(2):text())
            local dateText  = trim_u(cols:get(3):text())
            local amtText   = trim_u(cols:get(4):text())
            
            -- Recognize/skip header rows
            local looksLikeHeader = (qtyText:lower() == "anteile") or (amtText:lower() == "fondsguthaben")
            
            if not looksLikeHeader then
              local quantity     = parse_de_number(qtyText)
              local totalValue   = parse_de_number(amtText)
              -- Redemption price from table (may represent purchase price)
              local displayedUnitPrice = parse_de_number(priceText)

              -- Current price (implicit) = fund balance / quantity (if available)
              local currentPrice = nil
              if quantity > 0 and totalValue > 0 then
                currentPrice = totalValue / quantity
              end

              -- Purchase price: we set no purchase price (not from HDI table).
              local purchasePrice = nil

              -- Rounding
              local function round2(x) return math.floor(x * 100 + 0.5) / 100 end
              local function round6(x) return math.floor(x * 1e6 + 0.5) / 1e6 end

              quantity    = round6(quantity)
              if purchasePrice then purchasePrice = round6(purchasePrice) end
              if currentPrice then currentPrice = round6(currentPrice) end
              log("Calculated (current) price for '" .. name .. "': " .. (currentPrice and tostring(currentPrice) or "nil") .. " — Purchase price (redemption): " .. (purchasePrice and tostring(purchasePrice) or "nil") .. " (shares=" .. tostring(quantity) .. ", fund balance=" .. tostring(totalValue) .. ")")
              totalValue   = round2(totalValue)

              log("Found fund: " .. name .. " (ISIN: " .. (isin or "none") .. ", Quote: " .. quoteText .. ")")

              local function parse_date_to_timestamp(dstr)
                if not dstr then return nil end
                local d, m, y = string.match(dstr, "(%d%d)%.(%d%d)%.(%d%d%d%d)")
                if d and m and y then
                  return os.time({year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=0, min=0, sec=0})
                end
                return nil
              end

              local tradeTs = parse_date_to_timestamp(dateText)

              -- If ISIN available, try to get current price via justETF API
              local currentPriceFromAPI = nil
              if isin and isin ~= "" then
                local url = JUSTETF_API .. MM.urlencode(isin)
                local headers = {
                  ["Accept"] = "application/json, text/plain, */*",
                  ["Referer"] = "https://www.justetf.com/",
                  ["User-Agent"] = connection.useragent
                }
                local apiContent, apiCharset, apiMime = connection:request("GET", url, nil, nil, headers)
                if apiContent and apiContent ~= "" then
                  local ok2, parsed = pcall(function() return JSON(apiContent):dictionary() end)
                  if ok2 and parsed and parsed.etfs and parsed.etfs[1] then
                    local etf = parsed.etfs[1]
                    local raw = nil
                    if etf.latestQuote and etf.latestQuote.raw then raw = etf.latestQuote.raw end
                    if not raw and etf.quote and etf.quote.raw then raw = etf.quote.raw end
                    currentPriceFromAPI = tonumber(raw) or nil
                    if currentPriceFromAPI then
                      log("justETF price for ISIN " .. isin .. ": " .. tostring(currentPriceFromAPI))
                    else
                      log("justETF: no price found for ISIN " .. isin)
                    end
                  else
                    log("justETF: JSON parse failed or no etf entry for ISIN " .. isin)
                  end
                else
                  log("justETF: no response for ISIN " .. isin .. " (url=" .. url .. ")")
                end
              end

              -- MoneyMoney fields: set purchasePrice from redemption value, price from API if available, amount remains
              local finalPrice = (currentPriceFromAPI or purchasePrice)
              -- If USE_API is true, calculate amount from API price*quantity (if API price available),
              -- otherwise use site value.
              local amountToUse = totalValue
              if USE_API and currentPriceFromAPI and quantity and quantity > 0 then
                amountToUse = round2(currentPriceFromAPI * quantity)
              end

              log("FINAL position '" .. name .. "': price=" .. tostring(finalPrice) .. " purchasePrice=" .. tostring(purchasePrice) .. " quantity=" .. tostring(quantity) .. " amount(site)=" .. tostring(totalValue) .. " amount(used)=" .. tostring(amountToUse))

              -- Only return current market data, quantity and fund balance.
              -- purchasePrice and profit/loss are not reported because no transaction data is available.
              -- Only set price if we actually hold shares; hide purchasePrice always.
              local priceToSet = nil
              if USE_API and quantity and quantity > 0 and currentPriceFromAPI then
                priceToSet = currentPriceFromAPI
              end
              -- If user wants to hide purchase price and additionally specified
              -- that in this case the current price should also be hidden,
              -- then hide the price as well.
              if not SHOW_PURCHASE_PRICE and HIDE_PRICE_WHEN_PURCHASE_HIDDEN then
                priceToSet = nil
              end

              -- Only expose quantity and current fund amount. Do NOT expose purchasePrice or price.
              table.insert(positions, {
                name = name,
                isin = (isin ~= "" and isin or nil),
                -- Only show position amount, no quantity
                quantity = nil,
                currencyOfQuantity = nil,
                -- No price data output
                purchasePrice = nil,
                currencyOfPurchasePrice = nil,
                price = nil,
                currencyOfPrice = nil,
                -- amount = current position amount (API-based if USE_API, otherwise HDI site value)
                amount = amountToUse,
                originalAmount = nil,
                currencyOfOriginalAmount = (amountToUse and (account.currency or "EUR") or nil),
                tradeTimestamp = tradeTs,
              })
            end
          end
        end
      end
    end
  end

  if #positions == 0 then
    error("Fund data table not found or empty")
  end

  -- Cleanup: ensure no price/purchasePrice fields are returned (prevent MM deriving a price)
  for i = 1, #positions do
    local p = positions[i]
    p.purchasePrice = nil
    p.currencyOfPurchasePrice = nil
    p.price = nil
    p.currencyOfPrice = nil
    -- keep only amount (which may be 0) and name/isin
  end

  -- 4) Total balance
  local total = 0
  local totalNode = dHtml:xpath("//div[contains(@class,'fondsdaten') and contains(@class,'d-lg-flex')]//div[contains(@class,'zelle') and contains(@class,'align-right')][last()]")
  if totalNode:length() == 0 then
    totalNode = dHtml:xpath("//div[contains(@class,'zelle') and contains(@class,'zelle%-highlighted') and contains(@class,'align-right')][1]")
  end
  if totalNode:length() == 0 then
    totalNode = dHtml:xpath("//div[contains(@class,'optionHeadline')][.//label[contains(.,'Freie')]]//span[last()]")
  end
  if totalNode:length() > 0 then
    total = parse_de_number(totalNode:get(1):text())
  end

  log("Found positions: " .. #positions)
  -- Always calculate total amount from sum of individual position.amount.
  -- If USE_API is true, position.amount was already set to API price * quantity above.
  local computedTotal = 0
  for i = 1, #positions do
    local p = positions[i]
    if p.amount then computedTotal = computedTotal + p.amount end
  end
  total = math.floor(computedTotal * 100 + 0.5) / 100
  return {
    securities  = positions,
    total_value = total
  }
end

--------------------------------------------------------------------------------
-- Session management
--------------------------------------------------------------------------------
function EndSession()
  log("EndSession called")
  
  if connection then
    connection:close()
    connection = nil
  end
  
  sessionCookies = nil
  oktaSessionToken = nil
  
  return nil
end

log("HDI Extension loaded.")
