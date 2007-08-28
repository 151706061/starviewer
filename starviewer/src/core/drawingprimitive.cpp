/***************************************************************************
 *   Copyright (C) 2005 by Grup de Gràfics de Girona                       *
 *   http://iiia.udg.es/GGG/index.html?langu=uk                            *
 *                                                                         *
 *   Universitat de Girona                                                 *
 ***************************************************************************/
#include "drawingprimitive.h"

namespace udg {

DrawingPrimitive::DrawingPrimitive( QObject *parent ) 
    : QObject( parent ) 
{
    //assignem els valors per defecte que ens interessen
    setOpacity( 1. );
    setCoordinatesSystem( "WORLD" );
    visibilityOn();
    setColor( QColor( Qt::green ) );
    highlightOff();
}

};  // end namespace udg
