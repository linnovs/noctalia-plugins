--!nonstrict

function update()
  panel.render(ui.column({ flexGrow = 1 }, {}))
end

function onOpen()
  update()
end

update()