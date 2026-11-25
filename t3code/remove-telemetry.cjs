// Run in the upstream checkout, before either bundle is built.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');

let ts;
try {
  ts = require('typescript');
} catch (error) {
  if (error?.code !== 'MODULE_NOT_FOUND') throw error;
  ts = createRequire(path.join(process.cwd(), 'package.json'))('typescript');
}

function isExported(node) {
  const target = ts.isVariableDeclaration(node) ? node.parent?.parent : node;
  const modifiers = target && ts.canHaveModifiers(target) ? ts.getModifiers(target) : undefined;
  return Boolean(modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword));
}

// Edit declaration boundaries so unrelated changes in imports, formatting and
// function bodies do not invalidate a release. Missing required hooks fail the build.
function editModule(file, edit, optional = false) {
  if (optional && !fs.existsSync(file)) return;
  const source = fs.readFileSync(file, 'utf8');
  const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  assert.equal(tree.parseDiagnostics.length, 0, `Cannot parse ${file}`);
  const declarations = new Map();
  for (const statement of tree.statements) {
    const items = ts.isVariableStatement(statement) ? statement.declarationList.declarations : [statement];
    for (const item of items) {
      if (item.name) declarations.set(item.name.getText(), item);
    }
  }
  const edits = [];
  function replace(node, text) {
    assert(node, `Missing implementation in ${file}`);
    edits.push({ start: node.getStart(), end: node.end, text });
  }
  function insertAt(pos, text) {
    edits.push({ start: pos, end: pos, text });
  }
  function get(name) {
    assert(declarations.has(name), `Missing ${name} in ${file}`);
    return declarations.get(name);
  }
  function replaceFunctionBody(decl, blockText, exprText) {
    if (ts.isFunctionDeclaration(decl)) {
      assert(decl.body, `Missing function body in ${file}`);
      replace(decl.body, blockText);
      return;
    }
    if (ts.isVariableDeclaration(decl) && decl.initializer) {
      const fn = decl.initializer;
      if (ts.isArrowFunction(fn) || ts.isFunctionExpression(fn)) {
        assert(fn.body, `Missing function body in ${file}`);
        replace(fn.body, ts.isBlock(fn.body) ? blockText : (exprText ?? blockText));
        return;
      }
    }
    throw new Error(`Expected function declaration in ${file}`);
  }
  function removeVariable(name) {
    const variable = declarations.get(name);
    if (!variable) return;
    const list = variable.parent;
    assert(ts.isVariableDeclarationList(list) && list.declarations.length === 1, `Cannot remove ${name} in ${file}`);
    replace(list.parent, '');
  }
  edit({ tree, source, declarations, get, replace, insertAt, replaceFunctionBody, removeVariable });
  const ordered = [...edits].sort((a, b) => b.start - a.start || b.end - a.end);
  for (let i = 1; i < ordered.length; i += 1) {
    assert(ordered[i - 1].start >= ordered[i].end, `Overlapping edits in ${file}`);
  }
  let result = source;
  for (const { start, end, text } of ordered) {
    result = result.slice(0, start) + text + result.slice(end);
  }
  if (result !== source) fs.writeFileSync(file, result);
}

function collectTsxFiles(dir, files = []) {
  if (!fs.existsSync(dir)) return files;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      collectTsxFiles(full, files);
    } else if (
      entry.isFile() &&
      entry.name.endsWith('.tsx') &&
      !/\.(test|spec|stories)\.tsx$/.test(entry.name)
    ) {
      files.push(full);
    }
  }
  return files;
}

const telemetry = 'apps/server/src/telemetry';
const TELEMETRY_CONST_PATTERN =
  /T3CODE_POSTHOG_|ingest\.t3\.codes|us\.i\.posthog\.com|eu\.i\.posthog\.com|phc_[A-Za-z0-9]{20,}/;

editModule(`${telemetry}/AnalyticsService.ts`, ({ tree, declarations, get, replace, replaceFunctionBody }) => {
  // Preserve the release's service type, optional test layer, and runtime exports.
  function hasRecordMember(members) {
    return members.some((member) => member.name?.getText() === 'record');
  }
  function findInlineContract(node) {
    if ((ts.isTypeLiteralNode(node) || ts.isInterfaceDeclaration(node)) && hasRecordMember(node.members)) {
      return node.members;
    }
    return ts.forEachChild(node, findInlineContract);
  }
  function unwrapEffectResultKind(typeNode) {
    if (!typeNode || !ts.isTypeReferenceNode(typeNode)) return undefined;
    const typeName = typeNode.typeName.getText();
    if (typeName !== 'Effect' && !typeName.endsWith('.Effect')) return undefined;
    return typeNode.typeArguments?.[0]?.kind;
  }

  function findReferencedContract(node) {
    if (ts.isTypeReferenceNode(node)) {
      const ref = declarations.get(node.typeName.getText());
      if (ref) {
        const found = findInlineContract(ref);
        if (found) return found;
      }
    }
    return ts.forEachChild(node, findReferencedContract);
  }

  const serviceDecl = get('AnalyticsService');
  const members = findInlineContract(serviceDecl) ?? findReferencedContract(serviceDecl);
  assert(members, 'Missing AnalyticsService.record contract');

  let hasRecord = false;
  const implementations = members.map((member) => {
    const name = member.name?.getText();
    assert(name, `Unsupported analytics service member: ${member.getText()}`);
    if (name === 'record') hasRecord = true;
    if (ts.isPropertySignature(member) && member.type) {
      if (ts.isFunctionTypeNode(member.type)) {
        const result = unwrapEffectResultKind(member.type.type);
        if (result === ts.SyntaxKind.BooleanKeyword) return `${name}: () => Effect.succeed(false)`;
        if (result === ts.SyntaxKind.VoidKeyword) return `${name}: () => Effect.void`;
      } else {
        const result = unwrapEffectResultKind(member.type);
        if (result === ts.SyntaxKind.BooleanKeyword) return `${name}: Effect.succeed(false)`;
        if (result === ts.SyntaxKind.VoidKeyword) return `${name}: Effect.void`;
      }
    } else if (ts.isMethodSignature(member) && member.type) {
      const result = unwrapEffectResultKind(member.type);
      if (result === ts.SyntaxKind.BooleanKeyword) return `${name}: () => Effect.succeed(false)`;
      if (result === ts.SyntaxKind.VoidKeyword) return `${name}: () => Effect.void`;
    }
    throw new Error(`Unsupported analytics service member: ${member.getText()}`);
  });
  assert(hasRecord, 'Missing AnalyticsService.record member');

  const serviceImpl = `Effect.succeed(AnalyticsService.of({ ${implementations.join(', ')} }))`;
  if (declarations.has('make')) {
    const makeDecl = declarations.get('make');
    if (
      ts.isFunctionDeclaration(makeDecl) ||
      (ts.isVariableDeclaration(makeDecl) &&
        makeDecl.initializer &&
        (ts.isArrowFunction(makeDecl.initializer) || ts.isFunctionExpression(makeDecl.initializer)))
    ) {
      replaceFunctionBody(makeDecl, `{ return ${serviceImpl}; }`, serviceImpl);
    } else {
      replace(makeDecl.initializer, serviceImpl);
    }
  } else if (declarations.has('layer')) {
    replace(
      get('layer').initializer,
      `Layer.succeed(AnalyticsService, AnalyticsService.of({ ${implementations.join(', ')} }))`,
    );
  } else {
    throw new Error('Missing make or layer in AnalyticsService');
  }

  for (const statement of tree.statements) {
    if (!ts.isVariableStatement(statement)) continue;
    if (statement.declarationList.declarations.length !== 1) continue;
    const decl = statement.declarationList.declarations[0];
    const declName = decl.name?.getText();
    if (isExported(statement) || declName === 'make' || declName === 'layer') continue;
    if (TELEMETRY_CONST_PATTERN.test(statement.getText())) {
      replace(statement, '');
    }
  }
});

editModule('packages/shared/src/relayTracing.ts', ({ declarations, get, replaceFunctionBody }) => {
  const factory = declarations.get('layer') ?? get('makeRelayClientTracingLayer');
  replaceFunctionBody(factory, '{ return Layer.succeed(RelayClientTracer, Option.none()); }');
});

editModule('packages/shared/src/otelEnvironment.ts', ({ declarations, replaceFunctionBody }) => {
  const enabled = declarations.get('isRelayTracingEnabled');
  if (enabled) replaceFunctionBody(enabled, '{ return false; }', 'false');
}, true);

const NULL_RELAY_TRACING_CONFIG_BODY =
  '{ return null as { readonly tracesUrl: string; readonly tracesDataset: string; readonly tracesToken: string } | null; }';

editModule('apps/server/src/cloud/publicConfig.ts', ({ declarations, replaceFunctionBody }) => {
  const resolver =
    declarations.get('resolveRelayClientTracingConfig') ?? declarations.get('resolveRelayTracingConfig');
  if (resolver) replaceFunctionBody(resolver, NULL_RELAY_TRACING_CONFIG_BODY);
}, true);

editModule('apps/web/src/cloud/publicConfig.ts', ({ declarations, replaceFunctionBody }) => {
  const resolver =
    declarations.get('resolveRelayTracingConfig') ?? declarations.get('resolveRelayClientTracingConfig');
  if (resolver) replaceFunctionBody(resolver, NULL_RELAY_TRACING_CONFIG_BODY);
}, true);

editModule('apps/server/src/serverRuntimeStartup.ts', ({ declarations, replace }) => {
  const heartbeat = declarations.get('recordStartupHeartbeat');
  if (heartbeat) replace(heartbeat.initializer, 'Effect.void');
}, true);

editModule(`${telemetry}/ProviderUsageAnalytics.ts`, ({ source, declarations, replace }) => {
  // ProviderTurnAnalytics supplies no-op defaults when no layer is installed.
  const layer = declarations.get('layer');
  if (layer && source.includes('Context.Reference')) {
    replace(layer.initializer, 'Layer.empty');
  }
}, true);

editModule(`${telemetry}/DelegatedTaskAnalytics.ts`, ({ declarations, replace }) => {
  if (declarations.has('make')) {
    const idle = declarations.has('DelegatedTaskAnalytics')
      ? 'Effect.succeed(DelegatedTaskAnalytics.of({ onSubagent: () => Effect.void }))'
      : 'Effect.void';
    replace(declarations.get('make').initializer, idle);
  } else if (declarations.has('layer')) {
    replace(declarations.get('layer').initializer, 'Layer.empty');
  }
}, true);

editModule('packages/client-runtime/src/authorization/remote.ts', ({ declarations, replace }) => {
  const owners = declarations.get('readClientOwnerParams');
  if (owners) replace(owners.initializer, 'Effect.succeed<ClientOwnerParams>({})');
}, true);

editModule('apps/web/src/connection/platform.ts', ({ declarations, get, replace, removeVariable }) => {
  if (!declarations.has('analyticsDevice')) return;
  replace(get('analyticsDevice').initializer, '{ id: Effect.succeed(Option.none()) }');
  removeVariable('ANALYTICS_DEVICE_ID_KEY');
}, true);

for (const file of collectTsxFiles('apps/web/src')) {
  if (!fs.readFileSync(file, 'utf8').includes('ClerkProvider')) continue;
  editModule(file, ({ tree, replace, insertAt }) => {
    let importsClerkProvider = false;
    for (const statement of tree.statements) {
      if (
        ts.isImportDeclaration(statement) &&
        ts.isStringLiteral(statement.moduleSpecifier) &&
        statement.moduleSpecifier.text.startsWith('@clerk/') &&
        statement.importClause?.namedBindings &&
        ts.isNamedImports(statement.importClause.namedBindings) &&
        statement.importClause.namedBindings.elements.some(
          (element) => (element.propertyName?.text ?? element.name.text) === 'ClerkProvider',
        )
      ) {
        importsClerkProvider = true;
      }
    }
    let found = false;
    function visit(node) {
      if (
        (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
        node.tagName.getText() === 'ClerkProvider'
      ) {
        if (node.attributes.properties.length === 0) {
          insertAt(node.tagName.end, ' telemetry={false}');
        } else {
          const attrs = node.attributes.properties.filter((attr) => attr.name?.getText() !== 'telemetry');
          replace(node.attributes, [...attrs.map((attr) => attr.getText()), 'telemetry={false}'].join(' '));
        }
        found = true;
      }
      ts.forEachChild(node, visit);
    }
    visit(tree);
    assert(!importsClerkProvider || found, `Missing ClerkProvider in ${file}`);
  });
}

editModule('apps/web/src/state/managedPolicy.ts', ({ declarations, replace }) => {
  const notice = declarations.get('managedTelemetryOffMessage');
  if (!notice) return;
  const body = ts.isFunctionDeclaration(notice)
    ? notice.body
    : ts.isVariableDeclaration(notice) &&
        notice.initializer &&
        (ts.isArrowFunction(notice.initializer) || ts.isFunctionExpression(notice.initializer)) &&
        ts.isBlock(notice.initializer.body)
      ? notice.initializer.body
      : undefined;
  assert(body, 'Unknown managed telemetry notice body');
  const imageName = process.env.T3CODE_IMAGE_NAME || 'ghcr.io/nov12/t3code';
  const imageLiteral = JSON.stringify(imageName);
  if (body.getText().includes(imageLiteral)) return;

  const organization = `(policy?.limits?.telemetry === false ? policy.organization : ${imageLiteral})`;
  const returnStmt = [...body.statements].reverse().find(ts.isReturnStatement);
  assert(returnStmt?.expression, 'Unknown managed telemetry notice');

  if (ts.isConditionalExpression(returnStmt.expression)) {
    const enabledNotice = returnStmt.expression.whenTrue.getText();
    assert(enabledNotice.includes('policy.organization'), 'Unknown telemetry notice organization');
    replace(returnStmt.expression, enabledNotice.replace('policy.organization', organization));
    return;
  }

  const enabledNotice = returnStmt.expression.getText();
  assert(enabledNotice.includes('policy.organization'), 'Unknown telemetry notice organization');
  for (const statement of body.statements) {
    if (ts.isIfStatement(statement) && statement.getText().includes('telemetry') && !statement.elseStatement) {
      replace(statement, '');
    }
  }
  replace(returnStmt.expression, enabledNotice.replace('policy.organization', organization));
}, true);
