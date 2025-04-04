'use client'

import { getCoreRowModel, getSortedRowModel } from '@tanstack/react-table'
import { useMemo } from 'react'
import { BasicTable } from '~/components/table/basic-table'
import { useTable } from '~/hooks/use-table'
import { bridgesRisksColumns } from './columns'

import { TableFilters } from '~/components/table/filters/table-filters'
import { useFilterEntries } from '~/components/table/filters/use-filter-entries'
import type { BridgesRiskEntry } from '~/server/features/bridges/get-bridges-risk-entries'

export interface Props {
  entries: BridgesRiskEntry[]
}

export function BridgesRiskTable({ entries }: Props) {
  const filterEntries = useFilterEntries()

  const filteredEntries = useMemo(
    () => entries.filter(filterEntries),
    [entries, filterEntries],
  )

  const table = useTable({
    data: filteredEntries,
    columns: bridgesRisksColumns,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    manualFiltering: true,
    initialState: {
      sorting: [
        {
          id: '#',
          desc: false,
        },
      ],
      columnPinning: {
        left: ['#', 'logo'],
      },
    },
  })

  return (
    <div className="space-y-3 md:space-y-6">
      <TableFilters entries={entries} />
      <BasicTable table={table} />
    </div>
  )
}
