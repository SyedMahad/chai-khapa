// Standalone test runner: TypeScript compilation is performed by the test using the local global TS binary.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import ts from 'typescript'
const require = createRequire(import.meta.url)
const source = fs.readFileSync(new URL('../src/lib/errors.ts', import.meta.url), 'utf8')
const compiled = ts.transpileModule(source, { compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020} }).outputText
const module = { exports:{} }
new Function('module','exports','require',compiled)(module,module.exports,require)
const { describeAppError, diagnosticDetails } = module.exports

test('Supabase plain objects keep error code and message', () => {
  assert.match(describeAppError({code:'22023',message:'This accounting month is closed'}), /This accounting month is closed/)
})
test('Missing RPC produces actionable guidance', () => {
  assert.match(describeAppError({code:'PGRST202',message:'Function not found'}), /migration/)
})
test('Structured diagnostic fields are accessible without credentials', () => {
  const detail = diagnosticDetails({code:'42501',message:'Forbidden',hint:'Check policy',details:null})
  assert.deepEqual(detail,{code:'42501',message:'Forbidden',hint:'Check policy',details:null})
})
test('Network errors remain meaningful', () => {
  assert.match(describeAppError(new Error('Failed to fetch')), /Failed to fetch/)
})
