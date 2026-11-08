(() => {
  const tabs = document.getElementById('financeTabs');
  const cashPanel = document.getElementById('financeCashPanel');
  if (!tabs || !cashPanel || tabs.querySelector('[data-tab="dre"]')) return;

  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'btn';
  button.dataset.tab = 'dre';
  button.textContent = 'DRE';
  tabs.append(button);

  const panel = document.createElement('section');
  panel.className = 'card';
  panel.hidden = true;
  panel.id = 'financeDrePanel';
  panel.innerHTML = `
    <style>
      #financeDrePanel[hidden]{display:none}
      #financeDrePanel h2,#financeDrePanel h3{margin:0 0 6px}
      #financeDrePanel p{margin:4px 0 10px}
      #financeDrePanel .dre-filters{display:flex;align-items:end;gap:10px;flex-wrap:wrap;margin:12px 0}
      #financeDrePanel .dre-filters label{display:grid;gap:4px}
      #financeDrePanel .dre-filters input,#financeDrePanel .dre-filters select{min-width:115px}
      #financeDrePanel .dre-section{margin-top:16px}
      #financeDrePanel .dre-scroll{overflow:auto;border:1px solid #dce5ed;border-radius:7px}
      #financeDrePanel table{width:100%;border-collapse:collapse;font-size:12px}
      #financeDrePanel th,#financeDrePanel td{padding:4px 7px;border-bottom:1px solid #e1e9f0;text-align:left;vertical-align:top}
      #financeDrePanel th{background:#eaf2f9}
      #financeDrePanel tr:nth-child(even) td{background:#f8fbfd}
      #financeDrePanel td.dre-money,#financeDrePanel th.dre-money{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
      #financeDrePanel .dre-result{font-weight:700;color:#17603e}
      #financeDrePanel .dre-loss{font-weight:700;color:#a12d2d}
      #financeDrePanel .dre-dates{min-width:135px}
    </style>
    <h2>DRE gerencial</h2>
    <p class="sub">Resultado por moeda. O período usa a data da nota, operação ou despesa. Comissões conciliadas usam a primeira data do extrato do grupo.</p>
    <div class="dre-filters">
      <label>De <input type="date" data-dre="from"></label>
      <label>Até <input type="date" data-dre="to"></label>
      <label>Moeda <select data-dre="currency"><option value="">Todas</option></select></label>
      <button class="btn" type="button" data-dre="reload">Atualizar dados</button>
    </div>
    <p data-dre="status" role="status" aria-live="polite"></p>
    <div data-dre="results"></div>`;
  cashPanel.after(panel);

  const el = name => panel.querySelector('[data-dre="' + name + '"]');
  const cents = value => Math.round((Number(value) || 0) * 100);
  const normalized = value => String(value ?? '').trim().toUpperCase();
  const date = value => String(value || '').slice(0, 10);
  const formatDate = value => date(value).split('-').reverse().join('/') || '—';
  const formatAmount = new Intl.NumberFormat('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const money = value => formatAmount.format(value / 100);
  const unique = values => [...new Set(values.filter(Boolean))];
  const cancelled = value => ['CANCELLED', 'CANCELED', 'CANCELADO', 'VOID'].includes(normalized(value));
  const brokerage = value => ['BROKER', 'BROKERAGE', 'CORRETAGEM'].includes(normalized(value));
  const commissionExpense = value => /broker|comiss|commission|corret/i.test(value || '');
  const byId = rows => new Map(rows.map(row => [String(row.id), row]));
  const append = (map, key, value) => {
    if (!key) return;
    const values = map.get(key) || [];
    values.push(value);
    map.set(key, values);
  };

  const sources = {
    sales: ['aes_cash_sales_invoices', 'id,invoice_number,buyer_company,invoice_date,amount_try,status,currency,operation_kind:details->>operation_kind,operation_status:details->>operation_status'],
    expenses: ['aes_cash_gst_expenses', 'id,supplier_company,tax_invoice_number,expense_date,currency,total_amount,category:details->>category,description:details->>description'],
    trades: ['aes_trader_deals', 'id,trade_number,status,trade_date,supplier_id,buyer_id,product,quantity,currency,purchase_unit_price,sale_unit_price,purchase_contract_number,sale_proforma_number,purchase_commercial:purchase_flow->commercial,sale_commercial:sale_flow->commercial,operation_type,operation_kind:sale_flow->>operation_kind,operation_status:sale_flow->>operation_status,deleted_at:sale_flow->>deleted_at'],
    companies: ['companies', 'id,name'],
    movements: ['aes_finance_order_movements', 'id,order_number,movement_type'],
    orderPayments: ['aes_cash_order_payments', 'id,shipment_reference,deleted_at:details->>deletedAt'],
    manual: ['aes_cash_bank_financial_entries', 'id,bank_id,currency,entry_date,description,reference,debit,credit,kind,match_id'],
    matches: ['aes_cash_bank_matches', 'id,bank_id,currency,created_at'],
    items: ['aes_cash_bank_match_items', 'id,match_id,side,system_key,transaction_date:snapshot->>transaction_date,entry_date:snapshot->>date,currency:snapshot->>currency,debit:snapshot->>debit,credit:snapshot->>credit,party:snapshot->>party,invoice:snapshot->>invoice,description:snapshot->>description'],
    banks: ['aes_cash_banks', 'id,bank_name']
  };

  async function readAll(client, table, columns) {
    const records = [];
    const pageSize = 500;
    for (let offset = 0; ; offset += pageSize) {
      const { data, error } = await client.from(table).select(columns).order('id').range(offset, offset + pageSize - 1);
      if (error) throw new Error(table + ' · ' + error.message);
      records.push(...data);
      if (data.length < pageSize) return records;
    }
  }

  function build(data) {
    const matches = byId(data.matches);
    const banks = byId(data.banks);
    const companies = byId(data.companies);
    const movementById = byId(data.movements);
    const orderPaymentById = byId(data.orderPayments.filter(payment => !payment.deleted_at));
    const tradeByNumber = new Map();
    const activeTrades = data.trades.filter(trade => !trade.deleted_at);
    const tradeBySaleDocument = new Map();
    for (const trade of activeTrades) {
      append(tradeByNumber, normalized(trade.trade_number), trade);
      append(tradeBySaleDocument, normalized(trade.sale_proforma_number), trade);
    }
    const bankDates = new Map();
    const paymentsByKey = new Map();
    const paymentsByOrder = new Map();

    for (const item of data.items) {
      if (item.side === 'bank' && matches.has(String(item.match_id))) {
        append(bankDates, String(item.match_id), date(item.transaction_date || item.entry_date));
      }
    }
    const commissions = [];
    for (const item of data.items) {
      const matchId = String(item.match_id);
      const match = matches.get(matchId);
      const dates = unique(bankDates.get(matchId) || []).sort();
      if (item.side !== 'system' || !match || !dates.length || !item.system_key) continue;
      const debit = cents(item.debit), credit = cents(item.credit);
      const payment = { matchId, key: item.system_key, dates, debit, credit, currency: normalized(item.currency || match.currency), bank: banks.get(String(match.bank_id))?.bank_name || '' };
      append(paymentsByKey, item.system_key, payment);
      const movement = item.system_key.startsWith('receipt-') ? movementById.get(item.system_key.slice(8)) : null;
      if (movement?.movement_type === 'receipt') append(paymentsByOrder, normalized(movement.order_number), payment);
      const orderPayment = item.system_key.startsWith('order-') ? orderPaymentById.get(item.system_key.slice(6)) : null;
      if (orderPayment) append(paymentsByOrder, 'PAGAMENTO:' + normalized(orderPayment.shipment_reference), payment);
      if (item.system_key.startsWith('commission-') && (debit || credit)) {
        commissions.push({
          date: dates[0], document: item.invoice, party: item.party, description: item.description,
          currency: payment.currency, amount: credit - debit, payments: [payment], debit, credit
        });
      }
    }
    const paymentsFor = (keys, orders = []) => {
      const found = [...keys.flatMap(key => paymentsByKey.get(key) || []), ...orders.flatMap(order => paymentsByOrder.get(normalized(order)) || [])];
      return [...new Map(found.map(payment => [payment.matchId + '|' + payment.key, payment])).values()]
        .sort((a, b) => a.dates[0].localeCompare(b.dates[0]));
    };
    const isActual = (row, side) => row.payments.some(payment => payment.currency === row.currency && payment[side] > 0);
    const status = (record, row, side) => {
      if (cancelled(record.status)) return 'Cancelado';
      if (record.operation_status === 'finalized' || ['CONFIRMED', 'ISSUED', 'PAID', 'FINALIZED'].includes(normalized(record.status))) return 'Incluído';
      if (isActual(row, side)) return 'Incluído · conciliado';
      return normalized(record.status) === 'DRAFT' ? 'Rascunho' : 'Incluído';
    };
    const purchases = [], sales = [];
    const ledgerNumbers = new Set();
    for (const invoice of data.sales) {
      const number = normalized(invoice.invoice_number);
      if (number) ledgerNumbers.add(number);
      const linked = unique([...(tradeByNumber.get(number) || []), ...(tradeBySaleDocument.get(number) || [])]);
      const trade = linked.length === 1 ? linked[0] : null;
      const orders = trade ? ['TRADER:' + trade.id + ':sale'] : [number];
      const row = {
        date: date(invoice.invoice_date), document: invoice.invoice_number, order: trade?.trade_number || '',
        party: invoice.buyer_company, currency: normalized(invoice.currency),
        amount: cents(invoice.amount_try), payments: paymentsFor(['sales-' + invoice.id], orders)
      };
      row.status = brokerage(invoice.operation_kind || trade?.operation_kind) ? 'Corretagem · valor de terceiros' : status(invoice, row, 'credit');
      sales.push(row);
    }

    for (const trade of activeTrades) {
      const broker = brokerage(trade.operation_kind) || brokerage(trade.operation_type);
      for (const side of ['purchase', 'sale']) {
        if (side === 'purchase' && broker) continue;
        const buy = side === 'purchase';
        const doc = buy ? trade.purchase_contract_number : trade.sale_proforma_number;
        if (!buy && (ledgerNumbers.has(normalized(trade.trade_number)) || (doc && ledgerNumbers.has(normalized(doc))))) continue;
        const commercial = (buy ? trade.purchase_commercial : trade.sale_commercial) || {};
        const amount = cents(Number(commercial.quantity ?? trade.quantity) * Number(commercial.unit_price ?? (buy ? trade.purchase_unit_price : trade.sale_unit_price)));
        if (!amount && !doc) continue;
        const orders = ['TRADER:' + trade.id + ':' + side];
        if (buy && (tradeByNumber.get(normalized(trade.trade_number)) || []).length === 1) orders.push('PAGAMENTO:' + trade.trade_number);
        const row = {
          date: date(trade.trade_date), document: doc, order: trade.trade_number,
          party: companies.get(String(buy ? trade.supplier_id : trade.buyer_id))?.name,
          currency: normalized(trade.currency), amount, payments: paymentsFor([], orders)
        };
        row.status = broker ? 'Corretagem · valor de terceiros' : status(trade, row, buy ? 'debit' : 'credit');
        (buy ? purchases : sales).push(row);
      }
    }

    const expenses = data.expenses.map(expense => {
      const row = {
        date: date(expense.expense_date), document: expense.tax_invoice_number, party: expense.supplier_company,
        description: [expense.category, expense.description].filter(Boolean).join(' · '), currency: normalized(expense.currency),
        amount: cents(expense.total_amount), payments: paymentsFor(['expense-' + expense.id])
      };
      for (const payment of row.payments.filter(p => p.debit > 0 && commissionExpense(expense.category))) {
        commissions.push({ ...row, date: payment.dates[0], currency: payment.currency, debit: payment.debit,
          credit: 0, amount: -payment.debit, payments: [payment], expense: true });
      }
      return row;
    });
    const manual = data.manual.map(entry => ({
      date: date(entry.entry_date), document: entry.reference, party: banks.get(String(entry.bank_id))?.bank_name,
      description: entry.description, currency: normalized(entry.currency), debit: cents(entry.debit), credit: cents(entry.credit),
      status: entry.kind === 'adjustment' ? 'Ajuste de conciliação' : 'Lançamento manual',
      payments: paymentsFor([entry.kind === 'adjustment' ? 'adjustment-' + entry.id : 'financial-' + entry.id])
    }));
    return { purchases, sales, commissions, expenses, manual };
  }

  let report = null, request = 0;
  const sortByDate = (a, b) => b.date.localeCompare(a.date);
  const amountCell = value => ({ value: money(value), className: 'dre-money' });
  const paymentDates = row => ({
    value: row.payments.map(payment => {
      const dates = payment.dates.map(formatDate).join(', ');
      const bank = payment.bank ? ' · ' + payment.bank : '';
      return dates + bank + ' · ' + payment.currency + ' ' + money(payment.credit || payment.debit);
    }).join('\n') || 'Sem conciliação',
    className: 'dre-dates',
    preserveLines: true
  });

  function table(title, columns, rows, emptyText = 'Nenhum registro no filtro selecionado.') {
    const section = document.createElement('section');
    section.className = 'dre-section';
    const heading = document.createElement('h3');
    heading.textContent = title;
    section.append(heading);
    if (!rows.length) {
      const message = document.createElement('p');
      message.textContent = emptyText;
      section.append(message);
      return section;
    }
    const wrapper = document.createElement('div');
    wrapper.className = 'dre-scroll';
    const grid = document.createElement('table');
    const header = grid.createTHead().insertRow();
    for (const column of columns) {
      const cell = document.createElement('th');
      cell.scope = 'col';
      cell.textContent = column;
      header.append(cell);
    }
    const body = grid.createTBody();
    for (const row of rows) {
      const tr = body.insertRow();
      for (const value of row) {
        const cell = tr.insertCell();
        cell.textContent = (value?.value ?? value) || '—';
        if (value?.className) cell.className = value.className;
        if (value?.preserveLines) cell.style.whiteSpace = 'pre-line';
      }
    }
    wrapper.append(grid);
    section.append(wrapper);
    return section;
  }

  function render() {
    if (!report) return;
    const result = el('results');
    const from = el('from').value, to = el('to').value, currency = el('currency').value;
    result.replaceChildren();
    if (from && to && from > to) {
      el('status').textContent = 'A data inicial deve ser anterior ou igual à data final.';
      return;
    }
    el('status').textContent = '';
    const visible = rows => rows.filter(row =>
      (!currency || row.currency === currency) && (!from || row.date >= from) && (!to || (row.date && row.date <= to))
    ).sort(sortByDate);
    const purchases = visible(report.purchases), sales = visible(report.sales), expenses = visible(report.expenses);
    const commissions = visible(report.commissions), manual = visible(report.manual);
    const totals = new Map();
    const bucket = key => {
      if (!totals.has(key)) totals.set(key, { sales: 0, purchases: 0, expenses: 0, commissions: 0 });
      return totals.get(key);
    };
    const included = row => row.status.startsWith('Incluído');
    sales.filter(included).forEach(row => { bucket(row.currency).sales += row.amount; });
    purchases.filter(included).forEach(row => { bucket(row.currency).purchases += row.amount; });
    expenses.forEach(row => { bucket(row.currency).expenses += row.amount; });
    commissions.filter(row => !row.expense).forEach(row => { bucket(row.currency).commissions += row.amount; });
    const summary = [...totals].sort(([a], [b]) => a.localeCompare(b)).map(([key, values]) => {
      const gross = values.sales - values.purchases;
      const profit = gross - values.expenses + values.commissions;
      return [key || 'Moeda não informada', amountCell(values.sales), amountCell(values.purchases), amountCell(gross),
        amountCell(values.expenses), amountCell(values.commissions),
        { value: money(profit), className: 'dre-money ' + (profit < 0 ? 'dre-loss' : 'dre-result') }];
    });
    result.append(table('Resumo do resultado', ['Moeda', 'Vendas', 'Compras', 'Lucro bruto', 'Despesas', 'Comissões líquidas conciliadas', 'Lucro / Prejuízo'], summary));
    const note = document.createElement('p');
    note.className = 'sub';
    note.textContent = 'O resultado usa os registros incluídos de venda e compra, deduz despesas e incorpora comissões conciliadas. Corretagem de terceiros, lançamentos avulsos e ajustes ficam separados. Comissão paga via nota de despesa já está no total de despesas.';
    result.append(note);

    const documentHeaders = ['Data', 'Nota / Documento', 'Ordem', 'Empresa', 'Moeda', 'Valor', 'Situação na DRE', 'Pagamento conciliado · data do extrato / banco / valor vinculado'];
    const documentRow = row => [formatDate(row.date), row.document, row.order, row.party, row.currency, amountCell(row.amount), row.status, paymentDates(row)];
    result.append(
      table('Compras', documentHeaders, purchases.map(documentRow)),
      table('Vendas', documentHeaders, sales.map(documentRow)),
      table('Comissões pagas e conciliadas', ['Data do extrato', 'Documento', 'Empresa', 'Descrição', 'Moeda', 'Pago', 'Recebido', 'Datas e valores vinculados'],
        commissions.map(row => [formatDate(row.date), row.document, row.party, row.description, row.currency, amountCell(row.debit), amountCell(row.credit), paymentDates(row)])),
      table('Despesas', ['Data', 'Nota fiscal', 'Fornecedor', 'Categoria / Descrição', 'Moeda', 'Valor', 'Pagamento conciliado · data do extrato / banco / valor vinculado'],
        expenses.map(row => [formatDate(row.date), row.document, row.party, row.description, row.currency, amountCell(row.amount), paymentDates(row)])),
      table('Lançamentos avulsos · Bank Statement', ['Data', 'Banco', 'Referência', 'Descrição', 'Moeda', 'Débito', 'Crédito', 'Tipo', 'Conciliação · datas e valores vinculados'],
        manual.map(row => [formatDate(row.date), row.party, row.document, row.description, row.currency, amountCell(row.debit), amountCell(row.credit), row.status, paymentDates(row)]))
    );
  }

  async function load() {
    const current = ++request;
    report = null;
    el('results').replaceChildren();
    el('status').textContent = 'Carregando os dados da DRE…';
    el('reload').disabled = true;
    try {
      const client = window.aesSharedClient;
      if (!client) throw new Error('Entre no sistema para consultar a DRE.');
      const datasets = await Promise.all(Object.entries(sources).map(async ([key, source]) =>
        [key, await readAll(client, ...source)]));
      if (current !== request) return;
      report = build(Object.fromEntries(datasets));
      const select = el('currency');
      const previous = select.value;
      const currencies = unique(Object.values(report).flat().map(row => row.currency)).sort();
      select.replaceChildren(new Option('Todas', ''), ...currencies.map(value => new Option(value, value)));
      select.value = currencies.includes(previous) ? previous : '';
      render();
    } catch (error) {
      if (current === request) el('status').textContent = 'Não foi possível carregar a DRE. ' + error.message;
    } finally {
      if (current === request) el('reload').disabled = false;
    }
  }

  for (const name of ['from', 'to', 'currency']) el(name).addEventListener('change', render);
  el('reload').onclick = load;
  button.onclick = () => window.switchFinanceTab('dre');

  const original = window.switchFinanceTab;
  window.switchFinanceTab = function(tab) {
    panel.hidden = tab !== 'dre';
    if (panel.hidden) return original.apply(this, arguments);
    cashPanel.hidden = true;
    const historyPanel = document.getElementById('financeAllHistoryPanel');
    if (historyPanel) historyPanel.hidden = true;
    for (const id of ['financeFilters', 'financeOrderList', 'financeOrderWorkspace', 'financeHedgeStandalone']) {
      document.getElementById(id).style.display = 'none';
    }
    tabs.querySelectorAll('button').forEach(tabButton => tabButton.classList.toggle('primary', tabButton === button));
    window.financeActiveTab = 'dre';
    load();
  };
})();
