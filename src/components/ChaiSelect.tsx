import { useEffect, useId, useRef, useState } from 'react'
import type { KeyboardEvent } from 'react'

type Option = { value: string; label: string; disabled?: boolean }

type Props = {
  id: string
  value: string
  onChange: (value: string) => void
  options: Option[]
  placeholder?: string
  disabled?: boolean
  className?: string
}

/** Shared, keyboard-accessible Smoky Slate dropdown.  No browser-native option popup. */
export function ChaiSelect({ id, value, onChange, options, placeholder = 'Select an option', disabled = false, className = '' }: Props) {
  const [open, setOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const optionRefs = useRef<(HTMLButtonElement | null)[]>([])
  const generatedId = useId().replace(/:/g, '')
  const listId = `${generatedId}-listbox`
  const selectedIndex = options.findIndex(option => option.value === value)
  const selected = selectedIndex < 0 ? null : options[selectedIndex]

  useEffect(() => {
    if (!open) return
    function dismiss(event: PointerEvent) {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    document.addEventListener('pointerdown', dismiss)
    return () => document.removeEventListener('pointerdown', dismiss)
  }, [open])

  function firstEnabled(): number { return options.findIndex(option => !option.disabled) }
  function lastEnabled(): number {
    for (let i = options.length - 1; i >= 0; i--) if (!options[i].disabled) return i
    return -1
  }
  function nextEnabled(index: number, direction: 1 | -1): number {
    if (!options.length) return -1
    for (let distance = 1; distance <= options.length; distance++) {
      const candidate = (index + direction * distance + options.length * 2) % options.length
      if (!options[candidate].disabled) return candidate
    }
    return -1
  }
  function focusOption(index: number) {
    if (index >= 0) window.requestAnimationFrame(() => optionRefs.current[index]?.focus())
  }
  function expand(index: number) {
    if (disabled) return
    setOpen(true)
    focusOption(index >= 0 && !options[index]?.disabled ? index : firstEnabled())
  }
  function choose(option: Option) {
    if (option.disabled) return
    onChange(option.value)
    setOpen(false)
    window.requestAnimationFrame(() => triggerRef.current?.focus())
  }
  function onTriggerKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(event.key)) {
      event.preventDefault()
      expand(event.key === 'ArrowUp' ? lastEnabled() : selectedIndex >= 0 ? selectedIndex : firstEnabled())
    }
  }
  function onOptionKeyDown(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    if (event.key === 'Escape') {
      event.preventDefault(); setOpen(false); triggerRef.current?.focus()
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      focusOption(nextEnabled(index, event.key === 'ArrowDown' ? 1 : -1))
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault(); focusOption(event.key === 'Home' ? firstEnabled() : lastEnabled())
    } else if (event.key === 'Tab') {
      setOpen(false)
    }
  }

  return (
    <div ref={rootRef} className={`ck-select ${className}`} onBlurCapture={event => {
      if (!rootRef.current?.contains(event.relatedTarget as Node | null)) setOpen(false)
    }}>
      <button
        type="button" id={id} ref={triggerRef} className="ck-select-trigger"
        aria-haspopup="listbox" aria-expanded={open} aria-controls={open ? listId : undefined}
        aria-label={!selected ? placeholder : undefined} disabled={disabled}
        onClick={() => open ? setOpen(false) : expand(selectedIndex)} onKeyDown={onTriggerKeyDown}
      >
        <span className={!selected ? 'ck-select-placeholder' : undefined}>{selected?.label ?? placeholder}</span>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg>
      </button>
      {open && <div id={listId} className="ck-select-list" role="listbox" aria-label={placeholder}>
        {options.map((option, index) => <button
          key={`${option.value}-${index}`} ref={element => { optionRefs.current[index] = element }}
          type="button" role="option" aria-selected={option.value === value}
          disabled={option.disabled} tabIndex={-1}
          className={`ck-select-option ${option.value === value ? 'selected' : ''}`}
          onClick={() => choose(option)} onKeyDown={event => onOptionKeyDown(event, index)}
        >
          <span>{option.label}</span>
          {option.value === value && <span aria-hidden="true" className="ck-select-tick">✓</span>}
        </button>)}
      </div>}
    </div>
  )
}
