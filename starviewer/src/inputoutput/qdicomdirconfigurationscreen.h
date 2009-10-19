/***************************************************************************
 *   Copyright (C) 2005 by Grup de Grāfics de Girona                       *
 *   http://iiia.udg.es/GGG/index.html?langu=uk                            *
 *                                                                         *
 *   Universitat de Girona                                                 *
 ***************************************************************************/
#ifndef UDGQDICOMDIRCONFIGURATIONSCREEN_H
#define UDGQDICOMDIRCONFIGURATIONSCREEN_H

#include "ui_qdicomdirconfigurationscreenbase.h"

namespace udg {

class Status;

/** Widget en el que es configuren els parāmetres del programa de gravaciķ
*/
class QDICOMDIRConfigurationScreen : public QWidget, private ::Ui::QDICOMDIRConfigurationScreenBase
{
Q_OBJECT

public:
    /// Constructor de la classe
    QDICOMDIRConfigurationScreen( QWidget *parent = 0 );

    /// Destructor de classe
    ~QDICOMDIRConfigurationScreen();

public slots:
    /// Aplica els canvis de la configuraciķ
    bool applyChanges();

private slots:
    /// Mostra un QDialog per especificar on es troba el programa de gravaciķ en el disc dur
    void examinateDICOMDIRBurningApplicationPath();

private:
    /// Crea els connects dels signals i slots
    void createConnections();

    /// Carrega les dades de configuraciķ del programa de gravaciķ
    void loadBurningDefaults();

    /// Aplica els canvis fets a la configuraciķ del programa de gravaciķ
    void applyChangesDICOMDIR();

    /// Valida que els canvis de la configuraciķ siguin correctes
    bool validateChanges();
};

};// End namespace udg

#endif
